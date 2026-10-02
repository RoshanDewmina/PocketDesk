"""Bind test-without-building receipts to source inputs and complete built bundles."""
import hashlib,json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2]
def source_identity():
    files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=ROOT).decode().split('\0')
    # Include all source/resources/project/package inputs; documentation is not a compiler input.
    paths=[x for x in files if x and not x.startswith(('Docs/','docs/','outputs/','.claude/','.codex/','design/','script/claims/')) and not x.endswith(('.md','.pyc')) and '__pycache__' not in x.split('/')]
    return {x:hashlib.sha256((ROOT/x).read_bytes()).hexdigest() for x in sorted(paths) if (ROOT/x).is_file()}
def artifact_identity(dd):
    products=pathlib.Path(dd)/'Build/Products'
    paths=[]
    for x in products.rglob('*'):
        if x.is_file() and (x.suffix=='.xctestrun' or any(y.suffix in ['.app','.xctest'] for y in x.parents)):
            paths.append(x)
    if not paths: raise RuntimeError('No compiled claims artifacts; build first.')
    return {str(x.relative_to(products)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted(paths)}
def verify(dd):
    manifest=pathlib.Path(dd)/'claims-build-manifest.json'
    if not manifest.exists(): raise RuntimeError('No claims build manifest; run build first.')
    if json.loads(manifest.read_text()) != {'source':source_identity(),'artifacts':artifact_identity(dd)}:
        raise RuntimeError('Source or compiled artifacts differ from claims manifest; rebuild before testing.')
