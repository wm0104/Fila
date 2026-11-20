#!/usr/bin/env python3
"""Test viewer editing and HTML resource policies on the host."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fila-viewer-tests-') as directory:
    package = Path(directory)
    sources = package / 'Tests' / 'FilaViewerTests'
    sources.mkdir(parents=True)
    for name in ['Text/TextSearch.swift', 'Text/TextEncoding.swift', 'Text/TextReplacement.swift', 'Shared/AtomicSaveOperation.swift']:
        shutil.copy2(repo / 'Fila/Interface/Viewer' / name, sources / Path(name).name)
    for path in ['Fila/Interface/Viewer/Document/DocumentPreviewPolicy.swift',
                 'Fila/Interface/Viewer/Document/HTMLReadableText.swift', 'Tests/Viewer/HTMLPreviewTests.swift']:
        shutil.copy2(repo / path, sources / Path(path).name)
    shutil.copy2(repo / 'Tests/Viewer/ViewerTextTests.swift', sources / 'ViewerTextTests.swift')
    shutil.copy2(repo / 'Tests/Viewer/TextReplacementTests.swift', sources / 'TextReplacementTests.swift')
    shutil.copy2(repo / 'Tests/Viewer/AtomicSaveTests.swift', sources / 'AtomicSaveTests.swift')
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilaViewerHarness",
    platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "FilaViewerTests", swiftSettings: [.swiftLanguageMode(.v5)])]
)
''')
    command = ['swift', 'test', '--package-path', str(package)]
    if sys.platform.startswith('linux'):
        # Apple SDKs ship this module map; on Linux use the host's libxml2-dev.
        (package / 'xml.h').write_text('#include <libxml/HTMLparser.h>\n')
        module = package / 'libxml.modulemap'
        module.write_text('module libxml2 [system] { link "xml2" module HTMLparser { header "xml.h" export * } }\n')
        command += ['-Xcc', f'-fmodule-map-file={module}', '-Xcc', '-I/usr/include/libxml2']
    subprocess.run(command + sys.argv[1:], check=True, timeout=600)
