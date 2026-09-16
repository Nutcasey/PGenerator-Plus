import base64, hashlib, json, lzma, pathlib, subprocess, sys
encoded, destination = map(pathlib.Path, sys.argv[1:])
raw = lzma.decompress(base64.b64decode(encoded.read_text(), validate=True))
assert hashlib.sha256(raw).hexdigest() == 'c06c43663b8cc99c22cbd6b823cc12a976e6f9d70210332b1cbebb0aebf217ab', 'Repair payload checksum mismatch'
bundle = json.loads(raw)
base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=destination, text=True).strip()
assert base == bundle['base_sha'], 'Unexpected base commit'
paths = []
for entry in bundle['files']:
    relative = pathlib.PurePosixPath(entry['path'])
    assert not relative.is_absolute() and '..' not in relative.parts
    path = destination / relative
    if entry['before_sha256'] is None:
        assert not path.exists(), f'New file already exists: {relative}'
        before = b''
    else:
        before = path.read_bytes()
        assert hashlib.sha256(before).hexdigest() == entry['before_sha256'], f'Base file differs: {relative}'
    lines = before.decode('utf-8').splitlines(keepends=True)
    for start, end, replacement in reversed(entry['edits']):
        assert 0 <= start <= end <= len(lines)
        lines[start:end] = replacement.splitlines(keepends=True)
    after = ''.join(lines).encode('utf-8')
    assert hashlib.sha256(after).hexdigest() == entry['after_sha256'], f'Repaired file checksum differs: {relative}'
    if str(relative) == 't/browser/automation_review_fixes.cjs':
        # Keep mocked server state consistent with UI fixtures during live polling.
        text = after.decode('utf-8')
        old = "if(url==='/api/automation/runs/current')return {status:'ok'};"
        assert text.count(old) == 1 and text.count('pgAutomation.current={run:') == 3
        text = text.replace(old, "if(url==='/api/automation/runs/current')return window.mockCurrent||{status:'ok'};")
        text = text.replace('pgAutomation.current={run:', 'pgAutomation.current=window.mockCurrent={run:')
        # Define fetchJSON before the production script can schedule initialisation.
        early = "+'</script><script>'+read('webui-automation.js')+'</script><script>'+`"
        late = "`+'</script>';"
        assert text.count(early) == 1 and text.count(late) == 1
        text = text.replace(early, "+'</script><script>'+`")
        text = text.replace(late, "`+'</script><script>'+read('webui-automation.js')+'</script>';")
        after = text.encode('utf-8')
        assert hashlib.sha256(after).hexdigest() == 'fe0c1de0667fae23791f24865fa922791024889d5eb14a4c148fc1aa9c12c409'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(after)
    paths.append(str(relative))
    print(hashlib.sha256(after).hexdigest(), str(relative), flush=True)
subprocess.run(['git', 'add', '-N', '--', *paths], cwd=destination, check=True)
changed = subprocess.check_output(['git', 'diff', '--name-only'], cwd=destination, text=True).splitlines()
assert sorted(changed) == sorted(paths), 'Unexpected changed-file set'
subprocess.run(['git', 'diff', '--check'], cwd=destination, check=True)
print('Verified repair payload and all modified source files against exact base', base, flush=True)
