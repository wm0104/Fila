"""DEB development workflow contracts, not a GitHub Actions emulator.

Parse real YAML with macOS Ruby's standard-library Psych (no pip dependency).
Inspect jobs/steps/edges and exercise the artifact boundary with synthetic bytes.
No Xcode invocation, installation or actual Debian archive is needed here.
"""

import ast
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github/workflows'
GUARD = ("(github.event_name == 'push' && github.ref == 'refs/heads/deb-dev') || "
         "(github.event_name == 'pull_request' && github.base_ref == 'deb-dev') || "
         "(github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/deb-dev')")
PREFIX = 'fila-deb-${{ github.sha }}-${{ github.run_id }}'
VERIFY = 'python3 Scripts/verify-deb-artifacts.py build/Packages'
UPLOAD_PATHS = '\n'.join([
    'build/Packages/wiki.qaq.fila_${{ steps.packages.outputs.version }}_iphoneos-arm64e.deb',
    'build/Packages/Fila_${{ steps.packages.outputs.version }}_dSYMs.zip',
    'build/Packages/SHA256SUMS',
])


def load_workflow(name):
    # Missing Ruby is a test failure, not a skipped isolation check. Quoted "on"
    # in these workflows avoids YAML 1.1's boolean-key interpretation.
    result = subprocess.run([
        'ruby', '-rjson', '-ryaml', '-e',
        'puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false))',
        str(WORKFLOWS / name),
    ], check=True, capture_output=True, text=True, timeout=20)
    return json.loads(result.stdout)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def runs(job):
    return [step['run'].strip() for step in job['steps'] if 'run' in step]


def contract(ci, release, pages):
    require(ci['on'] == {'push': {'branches': ['deb-dev']},
                         'pull_request': {'branches': ['deb-dev']},
                         'workflow_dispatch': None}, 'branch/event triggers')
    require(ci['env']['BUILD_NUMBER_FLOOR'] == '1000', 'build floor')
    require(ci['permissions'] == {'contents': 'read'}, 'CI permissions')
    jobs = ci['jobs']
    require(set(jobs) == {'test', 'compile', 'floor-audit', 'packages'}, 'DEB-only jobs')
    for name, job in jobs.items():
        require(job['if'] == GUARD, f'{name}: branch/ref guard')
        expected = {'test': [], 'compile': [], 'floor-audit': ['compile'],
                    'packages': ['test', 'compile', 'floor-audit']}[name]
        require(job.get('needs', []) == expected, f'{name}: needs')
        require(not job.get('continue-on-error', False), f'{name}: failure must gate')
        for step in job['steps']:
            require(not step.get('continue-on-error', False), f'{name}: step failure must gate')
            require('if' not in step, f'{name}: required steps must not be conditional')
            if step.get('uses') == 'actions/checkout@v4':
                require('ref' not in step.get('with', {}), f'{name}: keep default PR merge checkout')

    host = runs(jobs['test'])
    for command in ['python3 -m unittest discover -s Scripts/Tests -v', 'make harness',
                    'python3 Scripts/test-app-search.py', 'python3 Scripts/test-app-viewer.py',
                    'python3 Scripts/test-app-deb.py', 'python3 Scripts/test-app-operations.py']:
        require(command in host, f'missing host check: {command}')
    build = runs(jobs['compile'])
    require('make compile DERIVED_DATA="${DERIVED_DATA:?}"' in build, 'compile/localization gate')
    require('make _package-deb FLAVOR=roothide DERIVED_DATA="${DERIVED_DATA:?}"' in build,
            'roothide-only DEB recipe')
    text = '\n'.join(build)
    require('BUILD="$(( GITHUB_RUN_NUMBER + BUILD_NUMBER_FLOOR ))"' in text, 'run build number')
    require('VERSION="$(make --no-print-directory print-version)"' in text, 'keep source version')
    require('*.dSYM' in text and 'zip -qry' in text, 'dSYMs')
    require('shasum -a 256' in text and '> SHA256SUMS' in text, 'SHA256 list')
    for forbidden in ['_packages', 'compile-sandboxed', 'package-ipa.sh', 'make ipa', 'make tipa',
                      'FLAVOR=rootless', 'iphoneos-arm64.deb']:
        require(forbidden not in text, f'forbidden recipe: {forbidden}')
    require(VERIFY in text, 'validate before upload')
    require(jobs['compile'].get('outputs') == {'attempt': '${{ steps.packages.outputs.attempt }}'},
            'compile: expose checked build attempt')
    require('echo "attempt=${GITHUB_RUN_ATTEMPT:?}" >> "$GITHUB_OUTPUT"' in text,
            'compile: record current attempt')
    attempt_guard = 'test "${BUILD_ATTEMPT:?}" = "${GITHUB_RUN_ATTEMPT:?}"'
    floor_check = next(step for step in jobs['floor-audit']['steps']
                       if step.get('name') == 'Verify exact DEB artifact set and checksums')
    require(floor_check.get('env') == {'BUILD_ATTEMPT': '${{ needs.compile.outputs.attempt }}'},
            'floor-audit: checked build attempt')
    require(floor_check['run'].strip() == 'set -euo pipefail\n' + attempt_guard + '\n' + VERIFY,
            'floor-audit: artifact verification and attempt isolation')
    collection = next(step for step in jobs['packages']['steps'] if step.get('id') == 'packages')
    require(collection.get('env') == {'BUILD_ATTEMPT': '${{ needs.compile.outputs.attempt }}'},
            'packages: checked build attempt')
    require(collection['run'].strip() == (
        'set -euo pipefail\n' + attempt_guard + '\n'
        'version="$(' + VERIFY + ')"\n'
        'echo "version=$version" >> "$GITHUB_OUTPUT"'), 'packages: verified version output')
    audit = '\n'.join(runs(jobs['floor-audit']))
    require('${#debs[@]} != 1' in audit, 'exactly one audit input')
    require('if [[ -z "$baseline" ]]' in audit and 'exit 1' in audit, 'baseline required')
    require('bash Scripts/audit-ios-floor.sh "$floor" "$app" "$daemon" "$helper"' in audit,
            'audit all packaged images')
    require(jobs['floor-audit']['runs-on'] == 'macos-26', 'older runtime runner')
    for name in jobs:
        for step in jobs[name]['steps']:
            if step.get('uses') == 'actions/download-artifact@v4':
                require(step['with'] == {'name': PREFIX, 'path': 'build/Packages/'},
                        f'{name}: exact current-run download, never a SHA wildcard or another run')
            if step.get('uses') == 'actions/upload-artifact@v4':
                options = step['with']
                require(options['name'] == PREFIX, 'one run/attempt artifact name')
                expected_paths = UPLOAD_PATHS if name == 'compile' else UPLOAD_PATHS.splitlines()[0]
                require(options['path'].strip() == expected_paths, 'closed upload allowlist')
                require(options.get('overwrite') is True, 'replace instead of accumulating artifacts')
                require(options['if-no-files-found'] == 'error', 'missing artifacts must fail')
                require(options['retention-days'] == (1 if name == 'compile' else 30), 'retention')
    require(sum(step.get('uses') == 'actions/download-artifact@v4'
                for job in jobs.values() for step in job['steps']) == 2, 'two download boundaries')
    require(sum(step.get('uses') == 'actions/upload-artifact@v4'
                for job in jobs.values() for step in job['steps']) == 2, 'two upload boundaries')
    for workflow in [release, pages]:
        require(workflow['on'] == {'workflow_dispatch': None}, 'no automatic publishing trigger')
        require(workflow['permissions'] == {'contents': 'read'}, 'no publishing permissions')
        for job in workflow['jobs'].values():
            require(job['if'] == '${{ false }}', 'publishing job must be unconditionally disabled')
            require(all(value == 'read' for value in job.get('permissions', {}).values()),
                    'no job write permissions')


def evaluate_guard(expression, context):
    # Only the boolean/equality subset actually used above; not an Actions
    # expression interpreter. Unknown syntax fails rather than being accepted.
    expression = re.sub(r'github\.(\w+)', r'\1', expression).replace('&&', ' and ').replace('||', ' or ')

    def visit(node):
        if isinstance(node, ast.Expression):
            return visit(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name):
            return context.get(node.id, '')
        if isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
            values = [visit(value) for value in node.values]
            return all(values) if isinstance(node.op, ast.And) else any(values)
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq):
            return visit(node.left) == visit(node.comparators[0])
        raise ValueError('unsupported guard syntax')

    return visit(ast.parse(expression, mode='eval'))


class WorkflowIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = [load_workflow(name) for name in ['ci.yml', 'release.yml', 'pages.yml']]

    def test_workflow_contract(self):
        contract(*self.workflows)

    def test_successful_run_exposes_one_artifact_containing_only_arm64e_deb(self):
        jobs = self.workflows[0]['jobs']
        built = next(step for step in jobs['compile']['steps']
                     if step.get('uses') == 'actions/upload-artifact@v4')['with']
        final = next(step for step in jobs['packages']['steps']
                     if step.get('uses') == 'actions/upload-artifact@v4')['with']
        self.assertEqual(built['name'], PREFIX)
        self.assertEqual(final['name'], built['name'])
        self.assertIs(final.get('overwrite'), True)
        self.assertIs(built.get('overwrite'), True)
        self.assertEqual(final['path'].strip(), UPLOAD_PATHS.splitlines()[0])
        for job in jobs.values():
            for step in job['steps']:
                if step.get('uses') == 'actions/download-artifact@v4':
                    self.assertEqual(step['with']['name'], built['name'])

    def test_reruns_keep_one_name_and_reject_a_previous_build_attempt(self):
        jobs = self.workflows[0]['jobs']
        upload = jobs['compile']['steps'][-1]['with']
        self.assertNotIn('github.run_attempt', upload['name'])
        self.assertIs(upload.get('overwrite'), True)
        for job_name, step_name in [
            ('floor-audit', 'Verify exact DEB artifact set and checksums'),
            ('packages', 'Verify exact DEB artifact set and read its version'),
        ]:
            step = next(s for s in jobs[job_name]['steps'] if s.get('name') == step_name)
            self.assertEqual(step['env']['BUILD_ATTEMPT'], '${{ needs.compile.outputs.attempt }}')
            for attempt, current, accepted in [('1', '1', True), ('2', '2', True),
                                                ('1', '2', False), ('', '2', False)]:
                with self.subTest(job=job_name, attempt=attempt, current=current):
                    environment = os.environ.copy()
                    environment.update(BUILD_ATTEMPT=attempt, GITHUB_RUN_ATTEMPT=current,
                                       GITHUB_OUTPUT=os.devnull)
                    stub = 'python3() { echo VERIFIED >&2; echo 0.8.4-4; };\n'
                    result = subprocess.run(['bash', '-c', stub + step['run']],
                                            env=environment, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode == 0, accepted)
                    self.assertEqual('VERIFIED' in result.stderr, accepted)

    def test_push_pr_and_dispatch_truth_table(self):
        for event in ['push', 'pull_request', 'workflow_dispatch', 'release']:
            for branch in ['deb-dev', 'ipa-dev', 'test', 'main']:
                for head in ['deb-dev', 'ipa-dev', 'feature']:
                    for base in ['deb-dev', 'ipa-dev']:
                        context = dict(event_name=event, ref='refs/heads/' + branch,
                                       head_ref=head, base_ref=base)
                        expected = ((event in ['push', 'workflow_dispatch'] and branch == 'deb-dev')
                                    or (event == 'pull_request' and base == 'deb-dev'))
                        with self.subTest(**context):
                            for job in self.workflows[0]['jobs'].values():
                                self.assertEqual(evaluate_guard(job['if'], context), expected)
        # A real PR uses the merge ref, not refs/heads/<head>. Its source
        # branch does not decide whether this target's DEB checks run.
        for head in ['feature', 'ipa-dev', 'deb-dev']:
            for base in ['deb-dev', 'ipa-dev', 'test', 'main']:
                context = dict(event_name='pull_request', ref='refs/pull/123/merge',
                               head_ref=head, base_ref=base)
                for job in self.workflows[0]['jobs'].values():
                    self.assertEqual(evaluate_guard(job['if'], context), base == 'deb-dev')
        for ref in ['refs/tags/v1.0.0', 'refs/pull/1/merge']:
            self.assertFalse(evaluate_guard(GUARD, dict(event_name='workflow_dispatch', ref=ref)))

    def test_contract_rejects_isolation_regressions(self):
        # Mutate the parsed graph, not strings in comments, to prove these
        # checks catch representative real regressions.
        mutations = [
            lambda c, r, p: c['on']['push']['branches'].append('ipa-dev'),
            lambda c, r, p: c['on']['pull_request'].update(branches=['ipa-dev']),
            lambda c, r, p: c['jobs']['test'].update({'if': 'true'}),
            lambda c, r, p: c['jobs']['test'].update({'if': GUARD.replace(
                "github.base_ref == 'deb-dev'", "github.base_ref == 'deb-dev' && github.head_ref == 'deb-dev'")}),
            lambda c, r, p: c['jobs']['test']['steps'][0].update({'with': {'ref': '${{ github.head_ref }}'}}),
            lambda c, r, p: c['jobs']['floor-audit'].update(needs=['compile', 'compile-sandboxed']),
            lambda c, r, p: c['jobs']['packages'].update(needs=['compile']),
            lambda c, r, p: c['jobs']['compile']['steps'].append({'run': 'make _packages-full'}),
            lambda c, r, p: c['jobs']['compile']['steps'].append({'run': 'make _package-deb FLAVOR=rootless'}),
            lambda c, r, p: c['jobs']['floor-audit']['steps'][-1].update(
                run=c['jobs']['floor-audit']['steps'][-1]['run'].replace('${#debs[@]} != 1', '${#debs[@]} != 2')),
            lambda c, r, p: c['jobs']['floor-audit']['steps'][1]['with'].update(name='fila-${{ github.sha }}-*'),
            lambda c, r, p: c['jobs']['compile']['steps'][-1]['with'].update(path='build/Packages/'),
            lambda c, r, p: c['jobs']['packages']['steps'][-1]['with'].pop('overwrite'),
            lambda c, r, p: c['jobs']['packages']['steps'][-1]['with'].update(overwrite='true'),
            lambda c, r, p: c['jobs']['compile']['steps'][-1]['with'].update(overwrite=False),
            lambda c, r, p: c['jobs']['compile']['outputs'].clear(),
            lambda c, r, p: c['jobs']['floor-audit']['steps'][2]['env'].clear(),
            lambda c, r, p: c['jobs']['packages']['steps'][2].update(
                run=c['jobs']['packages']['steps'][2]['run'].replace(
                    'test "${BUILD_ATTEMPT:?}" = "${GITHUB_RUN_ATTEMPT:?}"', 'true')),
            lambda c, r, p: c['jobs']['packages']['steps'][-1]['with'].update(name=PREFIX + '-verified'),
            lambda c, r, p: c['jobs']['packages']['steps'][-1]['with'].update(path=UPLOAD_PATHS),
            lambda c, r, p: c['jobs']['packages']['steps'][-1]['with'].update(path='build/Packages/*.deb'),
            lambda c, r, p: c['jobs']['packages']['steps'][2].update(
                run='echo "version=0.8.4-4" >> "$GITHUB_OUTPUT"'),
            lambda c, r, p: r['on'].update(push={'tags': ['v*']}),
            lambda c, r, p: r['jobs']['publish'].update({'if': 'true'}),
            lambda c, r, p: p['jobs']['deploy'].update({'if': 'true'}),
            lambda c, r, p: p['permissions'].update({'pages': 'write'}),
        ]
        for index, mutate in enumerate(mutations):
            workflows = copy.deepcopy(self.workflows)
            mutate(*workflows)
            with self.subTest(index=index), self.assertRaises(ValueError):
                contract(*workflows)

    def path_boundary_cases(self):
        jobs = self.workflows[0]['jobs']
        steps = {step.get('name'): step['run'] for job in jobs.values()
                 for step in job['steps'] if 'run' in step}
        cases = [
            (steps['Configure build paths'], variable)
            for variable in ['RUNNER_TEMP', 'GITHUB_ENV', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT']
        ]
        cases.append((steps['Compile and check localization'], 'DERIVED_DATA'))
        # Exercise the roothide recipe independently of compilation.
        cases.extend((line, 'DERIVED_DATA') for line in
                     steps['Package and verify roothide DEB only'].splitlines()
                     if line.strip().startswith('make '))
        cases.extend((steps['Archive dSYMs'], variable)
                     for variable in ['DERIVED_DATA', 'GITHUB_WORKSPACE'])
        cases.append((steps['Audit every packaged image at the floor'], 'RUNNER_TEMP'))
        return cases

    def assert_rejects_missing_path(self, script, variable, value):
        with tempfile.TemporaryDirectory(prefix='fila-path-contract-') as directory:
            environment = os.environ.copy()
            environment.update(RUNNER_TEMP=directory, DERIVED_DATA=directory,
                               GITHUB_WORKSPACE=directory, GITHUB_RUN_ID='1',
                               GITHUB_RUN_ATTEMPT='1', GITHUB_ENV=str(Path(directory) / 'env'))
            if value is None:
                environment.pop(variable, None)
            else:
                environment[variable] = value
            # Even a regressed workflow cannot compile, unpack, create folders
            # or leave the fixture directory. A call is a failed test, not work.
            stubs = ('unexpected() { echo UNEXPECTED_COMMAND >&2; return 97; }\n'
                     'make() { unexpected; }; zip() { unexpected; }; cd() { unexpected; }\n'
                     'mkdir() { unexpected; }; dpkg-deb() { unexpected; }\n'
                     'xcrun() { unexpected; }; python3() { unexpected; }\n')
            result = subprocess.run(['bash', '-c', stubs + script], cwd=directory,
                                    env=environment, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('UNEXPECTED_COMMAND', result.stderr)
            self.assertRegex(result.stderr, rf'{variable}: (parameter null or not set|unbound variable)')

    def test_path_boundaries_reject_empty_and_unset_variables_before_work(self):
        for script, variable in self.path_boundary_cases():
            for value in ['', None]:
                with self.subTest(script=script, variable=variable, value=value):
                    self.assert_rejects_missing_path(script, variable, value)

    def test_path_checks_detect_unguarded_mutations(self):
        for script, variable in self.path_boundary_cases():
            mutated = script.replace('${' + variable + ':?}', '$' + variable)
            self.assertNotEqual(mutated, script)
            with self.subTest(variable=variable, script=script), self.assertRaises(AssertionError):
                self.assert_rejects_missing_path(mutated, variable, '')

    def test_all_embedded_shell_parses(self):
        for workflow in self.workflows:
            for name, job in workflow['jobs'].items():
                for step in job['steps']:
                    if 'run' in step:
                        with self.subTest(job=name, step=step.get('name')):
                            subprocess.run(['bash', '-n'], input=step['run'], text=True,
                                           capture_output=True, check=True, timeout=10)


class ArtifactBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('deb_artifacts', ROOT / 'Scripts/verify-deb-artifacts.py')
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.version = '0.8.4-3'
        self.names = [f'wiki.qaq.fila_{self.version}_iphoneos-arm64e.deb',
                      f'Fila_{self.version}_dSYMs.zip']
        # Not archives: only testing transfer bytes, never a fake installable DEB.
        for name in self.names:
            (self.directory / name).write_bytes(('synthetic bytes: ' + name).encode())
        self.manifest = self.directory / 'SHA256SUMS'
        self.manifest.write_text(''.join(hashlib.sha256((self.directory / name).read_bytes()).hexdigest()
                                         + '  ' + name + '\n' for name in self.names))

    def reject(self):
        with self.assertRaises(ValueError):
            self.helper.validate(self.directory)

    def test_exact_arm64e_deb_and_symbols_pass(self):
        self.assertEqual(self.helper.validate(self.directory), self.version)

    def test_unexpected_archives_files_and_directories_fail(self):
        for name in ['Fila.ipa', 'Fila.tipa', 'old.deb', 'SHA256SUMS.full', '.hidden',
                     f'wiki.qaq.fila_{self.version}_iphoneos-arm64.deb']:
            with self.subTest(name=name):
                path = self.directory / name
                path.write_bytes(b'extra')
                self.reject()
                path.unlink()
        (self.directory / 'directory').mkdir()
        self.reject()

    def test_missing_required_files_fail(self):
        for name in self.names + ['SHA256SUMS']:
            path = self.directory / name
            data = path.read_bytes()
            path.unlink()
            with self.subTest(name=name):
                self.reject()
            path.write_bytes(data)

    def test_wrong_or_mixed_versions_fail(self):
        path = self.directory / self.names[0]
        path.rename(self.directory / path.name.replace(self.version, '0.8.4-4'))
        self.reject()

    def test_duplicate_missing_extra_and_traversal_manifest_entries_fail(self):
        original = self.manifest.read_text()
        first = original.splitlines(keepends=True)[0]
        for text in [original + first, ''.join(original.splitlines(keepends=True)[1:]),
                     original + '0' * 64 + '  extra.ipa\n',
                     original.replace(self.names[0], '../' + self.names[0]),
                     original.replace('  ', ' ', 1), original + '\n']:
            self.manifest.write_text(text)
            with self.subTest(text=text):
                self.reject()

    def test_corrupted_bytes_fail(self):
        (self.directory / self.names[1]).write_bytes(b'corrupted')
        self.reject()

    def test_payload_or_manifest_symlink_fails(self):
        for name in [self.names[0], 'SHA256SUMS']:
            path = self.directory / name
            data = path.read_bytes()
            path.unlink()
            path.symlink_to(self.names[1])
            with self.subTest(name=name):
                self.reject()
            path.unlink()
            path.write_bytes(data)


if __name__ == '__main__':
    unittest.main()
