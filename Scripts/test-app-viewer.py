#!/usr/bin/env python3
"""Test the app's production text matching and encoding logic on the host."""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fila-viewer-tests-') as directory:
    package = Path(directory)
    sources = package / 'Tests' / 'FilaViewerTests'
    sources.mkdir(parents=True)
    for name in ['Text/TextSearch.swift', 'Text/TextEncoding.swift']:
        shutil.copy2(repo / 'Fila/Interface/Viewer' / name, sources / Path(name).name)
    shutil.copy2(repo / 'Tests/Viewer/ViewerTextTests.swift', sources / 'ViewerTextTests.swift')
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilaViewerHarness",
    platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "FilaViewerTests", swiftSettings: [.swiftLanguageMode(.v5)])]
)
''')
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True)
