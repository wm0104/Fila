#!/usr/bin/env python3
"""Test the real operation center, replacing only transport and presentation."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fila-operation-tests-') as directory:
    package = Path(directory)
    sources = package / 'Tests' / 'FilaOperationTests'
    sources.mkdir(parents=True)
    for name in ['OperationCenter.swift', 'OperationCenter+Operation.swift', 'OperationCenter+Kind.swift', 'OperationCenter+Text.swift']:
        shutil.copy2(repo / 'Fila/Services/Transfers' / name, sources)
    shutil.copy2(repo / 'Fila/Services/Installation/TrollStoreInbox.swift', sources)
    for name in ['OperationCenterSupport.swift', 'OperationCenterTests.swift', 'TrollStoreInboxTests.swift']:
        shutil.copy2(repo / 'Tests/Tasks' / name, sources)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilaOperationHarness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: DEPENDENCY)],
    targets: [.testTarget(name: "FilaOperationTests", dependencies: [
        .product(name: "FilaClient", package: "FilaKit"),
        .product(name: "FilaProtocol", package: "FilaKit"),
        .product(name: "FilaLog", package: "FilaKit")
    ], swiftSettings: [.swiftLanguageMode(.v5)])]
)
'''.replace('DEPENDENCY', json.dumps(str(repo / 'Packages/FilaKit'))))
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True, timeout=600)
