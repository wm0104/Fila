#!/usr/bin/env python3
"""Test production deb metadata and save/build coordination on the host."""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fila-deb-tests-') as directory:
    package = Path(directory)
    sources = package / 'Tests' / 'FilaDebTests'
    sources.mkdir(parents=True)
    shutil.copy2(repo / 'Fila/Services/Installation/DebianPackageInformation.swift', sources)
    shutil.copy2(repo / 'Fila/Services/Installation/DebianPackageBuildOperation.swift', sources)
    shutil.copy2(repo / 'Fila/Interface/Viewer/Shared/AtomicSaveOperation.swift', sources)
    shutil.copy2(repo / 'Tests/Viewer/DebianPackageInformationTests.swift', sources)
    shutil.copy2(repo / 'Tests/Viewer/DebianPackageBuildOperationTests.swift', sources)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilaDebHarness",
    platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "FilaDebTests", swiftSettings: [.swiftLanguageMode(.v5)])]
)
''')
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True, timeout=600)
