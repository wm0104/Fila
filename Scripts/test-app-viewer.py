#!/usr/bin/env python3
"""Test viewer editing, pane geometry and HTML resource policies on the host."""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fila-viewer-tests-') as directory:
    package = Path(directory)
    sources = package / 'Tests' / 'FilaViewerTests'
    sources.mkdir(parents=True)
    for name in ['Text/TextSearch.swift', 'Text/TextEncoding.swift', 'Text/TextReplacement.swift', 'Shared/AtomicSaveOperation.swift']:
        shutil.copy2(repo / 'Fila/Interface/Viewer' / name, sources / Path(name).name)
    for path in ['Fila/Interface/Tabs/PaneLayout.swift', 'Fila/Interface/Viewer/Document/DocumentPreviewPolicy.swift',
                 'Tests/Viewer/PaneAndHTMLTests.swift']:
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
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True, timeout=600)
