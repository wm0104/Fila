#!/usr/bin/env python3
"""Exercise the app's real paged search with a host-only transport double."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fila-search-tests-') as directory:
    package = Path(directory)
    sources = package / 'Tests' / 'FilaSearchTests'
    sources.mkdir(parents=True)
    shutil.copy2(repo / 'Fila/Services/Files/FileSearch.swift', sources / 'FileSearch.swift')
    shutil.copy2(repo / 'Tests/Search/FileSearchTests.swift', sources / 'FileSearchTests.swift')
    shutil.copy2(repo / 'Tests/Search/FileSearchChangesTests.swift', sources / 'FileSearchChangesTests.swift')
    shutil.copy2(repo / 'Fila/Interface/Browser/PathFavoritesTransition.swift', sources / 'PathFavoritesTransition.swift')
    shutil.copy2(repo / 'Tests/Search/PathFavoritesTransitionTests.swift', sources / 'PathFavoritesTransitionTests.swift')
    dependency = json.dumps(str(repo / 'Packages/FilaKit'))
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilaSearchHarness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: DEPENDENCY)],
    targets: [.testTarget(
        name: "FilaSearchTests",
        dependencies: [
            .product(name: "FilaProtocol", package: "FilaKit"),
            .product(name: "FilaLog", package: "FilaKit")
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )]
)
'''.replace('DEPENDENCY', dependency))
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True)
