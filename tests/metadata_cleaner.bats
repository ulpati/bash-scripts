#!/usr/bin/env bats
# Tests for metadata-cleaner/metadata_cleaner.sh. They need exiftool and qpdf; the mat2 tests are
# skipped when mat2 is not installed. Missing programs are simulated with path_without.
# shellcheck disable=SC2016 # single quotes keep attack strings literal on purpose

bats_require_minimum_version 1.5.0 # for "run !"

setup() {
    load test_helper
    isolate_environment
    command -v exiftool >/dev/null 2>&1 || skip "exiftool is not installed"
    SCRIPT="$REPO_ROOT/metadata-cleaner/metadata_cleaner.sh"
    FIX="$BATS_TEST_DIRNAME/fixtures"
    T="$BATS_TEST_TMPDIR/target"
    OUT="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$T" "$OUT"
    cd "$BATS_TEST_TMPDIR" || return 1
}

clean() {
    run "$BASH_UNDER_TEST" "$SCRIPT" "$@"
}

tagged_jpg() {
    cp "$FIX/tiny.jpg" "$1"
    exiftool -q -overwrite_original -Artist="Mario Rossi" -GPSLatitude=45.46 -GPSLatitudeRef=N \
        -Comment="shot at home" -- "$1"
}

tag() { exiftool -s3 "-$1" -- "$2"; }

# A PATH in which the given commands cannot be found, to test what happens when they are missing.
# Every other program stays available through a link in a private folder.
path_without() {
    local bin="$BATS_TEST_TMPDIR/path-without" dir name
    mkdir -p "$bin"
    local IFS=:
    for dir in $PATH; do
        [[ -d "$dir" ]] || continue
        # ln leaves names linked from an earlier PATH folder alone, as the shell would.
        find "$dir/" -maxdepth 1 ! -type d -perm -u=x -print0 | xargs -0 -r ln -s -t "$bin" 2>/dev/null || true
    done
    for name in "$@"; do rm -f -- "${bin:?}/${name:?}"; done
    printf '%s' "$bin"
}

# A minimal Word document whose properties name an author.
make_docx() {
    python3 - "$1" <<'PY'
import sys, zipfile
parts = {
    "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>',
    "_rels/.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>',
    "word/document.xml": '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello reader</w:t></w:r></w:p></w:body></w:document>',
    "docProps/core.xml": '<?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Mario Rossi</dc:creator></cp:coreProperties>',
}
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    for name, text in parts.items():
        archive.writestr(name, text)
PY
}

# Succeeds when any part of a zip-based document contains the text.
zip_contains() {
    python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); sys.exit(0 if any(sys.argv[2].encode() in z.read(n) for n in z.namelist()) else 1)' "$1" "$2"
}

# Year of the last modification.
mtime_year() { date -r "$1" +%Y; }

@test "help works without exiftool; usage errors exit with 2" {
    PATH="/usr/bin:/bin" run "$BASH_UNDER_TEST" "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    clean
    [ "$status" -eq 2 ]
    clean --bogus "$T"
    [ "$status" -eq 2 ]
    clean --jobs 0 "$T"
    [ "$status" -eq 2 ]
    clean --yes "$T/missing"
    [ "$status" -eq 1 ]
}

@test "a file called --worker cannot start the internal worker mode" {
    tagged_jpg "$T/photo.jpg"
    clean --worker "$T/photo.jpg"
    [ "$status" -eq 2 ]
    [ "$(tag Artist "$T/photo.jpg")" = "Mario Rossi" ]
}

@test "short options, --version and every dry-run alias" {
    tagged_jpg "$T/photo.jpg"
    clean --version
    [ "$status" -eq 0 ] && [ "$output" = "metadata_cleaner.sh 1.0.0" ]
    for flag in -n -d --dry-run; do
        clean -r "$flag" "$T"
        [ "$status" -eq 0 ] && [[ "$output" == *"would clean"*"photo.jpg"* ]]
    done
    printf 'password = "hunter2"\n' > "$T/app.py"
    clean -r -y -v -a -b -c -p -j 2 --backup-dir "$BATS_TEST_TMPDIR/bk" "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[VERBOSE] Parallel mode: 2 workers"* ]]
    [ "$(cat "$T/app.py")" = 'password = "[REDACTED]"' ]
    [ -z "$(tag Artist "$T/photo.jpg")" ]
    tar -tzf "$BATS_TEST_TMPDIR/bk.tar.gz" | grep -q "photo.jpg"
}

@test "asks for confirmation and refuses without a terminal" {
    tagged_jpg "$T/photo.jpg"
    clean -r "$T"
    [ "$status" -eq 3 ]
    [ "$(tag Artist "$T/photo.jpg")" = "Mario Rossi" ]
}

@test "removes EXIF and GPS data, TIFF camera tags and video recording dates" {
    tagged_jpg "$T/photo.jpg"
    cp "$FIX/tiny.png" "$T/image.png"
    exiftool -q -overwrite_original -XMP:Creator="Mario Rossi" -- "$T/image.png"
    cp "$FIX/tiny.tif" "$T/scan.tif"
    exiftool -q -overwrite_original -Make=Canon -Model="EOS 5D" -Artist="Mario Rossi" -- "$T/scan.tif"
    cp "$FIX/tiny.mov" "$T/clip.mov"
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [ -z "$(tag Artist "$T/photo.jpg")$(tag GPSLatitude "$T/photo.jpg")$(tag Comment "$T/photo.jpg")" ]
    [ -z "$(tag Creator "$T/image.png")" ]
    [ -z "$(tag Make "$T/scan.tif")$(tag Model "$T/scan.tif")$(tag Artist "$T/scan.tif")" ]
    [ "$(tag CreateDate "$T/clip.mov")" = "0000:00:00 00:00:00" ]
    [[ "$output" == *"Cleaned: 4"* ]]
}

@test "cleaned files keep their permissions and every hard link is cleaned" {
    tagged_jpg "$T/photo.jpg"
    chmod 640 "$T/photo.jpg"
    ln "$T/photo.jpg" "$BATS_TEST_TMPDIR/link.jpg"
    printf '{"cells":[{"cell_type":"code","execution_count":3,"metadata":{},"outputs":[],"source":["1"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}\n' \
        > "$T/nb.ipynb"
    ln "$T/nb.ipynb" "$BATS_TEST_TMPDIR/link.ipynb"
    clean --yes "$T/photo.jpg" "$T/nb.ipynb"
    [ "$status" -eq 0 ]
    [ -z "$(tag Artist "$BATS_TEST_TMPDIR/link.jpg")" ]
    run ! grep -q '"execution_count": 3' "$BATS_TEST_TMPDIR/link.ipynb"
    [ "$(stat -c '%a' "$T/photo.jpg")" = "640" ]
}

@test "files without metadata are not reported as cleaned" {
    cp "$FIX/tiny.png" "$T/plain.png"
    printf 'just text\n' > "$T/notes.txt"
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 0  Attributes only: 2"* ]]
}

@test "cleaning twice changes nothing the second time" {
    tagged_jpg "$T/photo.jpg"
    cp "$FIX/link.pdf" "$T/doc.pdf"
    clean -r --yes "$T"
    [[ "$output" == *"Cleaned: 2"* ]]
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 0  Attributes only: 2"* ]]
}

@test "cleans Jupyter notebooks and keeps them valid" {
    cat > "$T/nb.ipynb" <<'EOF'
{"cells": [{"cell_type": "code", "execution_count": 7, "metadata": {"tags": ["x"]},
  "outputs": [{"output_type": "execute_result", "execution_count": 7, "metadata": {"a": 1},
               "data": {"text/plain": ["42"]}}], "source": ["6*7"]}],
 "metadata": {"author": "Mario Rossi", "kernelspec": {"name": "python3", "display_name": "venv-mario"},
              "language_info": {"name": "python", "version": "3.12.3"}},
 "nbformat": 4, "nbformat_minor": 5}
EOF
    cp "$T/nb.ipynb" "$T/keep.ipynb"
    clean --yes "$T/nb.ipynb"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; nb=json.load(open(sys.argv[1])); c=nb["cells"][0]; print(nb["metadata"], c["execution_count"], c["outputs"], c["metadata"])' "$T/nb.ipynb"
    [ "$output" = "{'language_info': {'name': 'python'}} None [] {}" ]
    clean --yes --keep-outputs "$T/keep.ipynb"
    run python3 -c 'import json,sys; o=json.load(open(sys.argv[1]))["cells"][0]["outputs"][0]; print(o["execution_count"], o["metadata"], o["data"])' "$T/keep.ipynb"
    [ "$output" = "None {} {'text/plain': ['42']}" ]
}

@test "malicious file names are never executed" {
    tagged_jpg "$T/x\$(touch PWNED1).jpg"
    tagged_jpg "$T/\"; touch PWNED2; \".jpg"
    tagged_jpg "$T/-overwrite_original.jpg"
    clean -r --yes --parallel --jobs 2 "$T"
    [ "$status" -eq 0 ]
    [ ! -e PWNED1 ] && [ ! -e "$T/PWNED1" ]
    [ ! -e PWNED2 ] && [ ! -e "$T/PWNED2" ]
    [ -z "$(tag Artist "$T/-overwrite_original.jpg")" ]
    [ -z "$(tag Artist "$T/x\$(touch PWNED1).jpg")" ]
    [[ "$output" == *"Cleaned: 3"* ]]
}

@test "control characters in file names never reach the terminal or the report" {
    tagged_jpg "$T/evil"$'\e]0;owned\a'".jpg"
    clean -r --dry-run "$T"
    [[ "$output" == *'evil?]0;owned?.jpg'* ]]
    [[ "$output" != *$'\e'* ]]
    clean -r --yes --verbose --report "$BATS_TEST_TMPDIR/r.txt" "$T"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\e'* ]]
    run ! grep -q $'\e' "$BATS_TEST_TMPDIR/r.txt"
    grep -qF 'evil?]0;owned?.jpg' "$BATS_TEST_TMPDIR/r.txt"
}

@test "symbolic links are not followed" {
    tagged_jpg "$OUT/private.jpg"
    ln -s "$OUT/private.jpg" "$T/link.jpg"
    ln -s "$OUT" "$T/linkdir"
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [ "$(tag Artist "$OUT/private.jpg")" = "Mario Rossi" ]
    clean --yes "$T/link.jpg"
    [ "$status" -eq 0 ]
    [ "$(tag Artist "$OUT/private.jpg")" = "Mario Rossi" ]
}

@test "helper tools never write next to the file, so planted links cannot redirect them" {
    printf 'keep me\n' > "$OUT/victim"
    tagged_jpg "$T/photo.jpg"
    cp "$FIX/native-metadata.pdf" "$T/doc.pdf"
    ln -s ../outside/created "$T/photo.jpg_exiftool_tmp"   # ExifTool's temporary file name
    ln -s ../outside/victim "$T/doc.pdf_exiftool_tmp"
    ln -s ../outside/victim "$T/photo.cleaned.jpg"         # mat2's output file name
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 2"* ]]
    [ -z "$(tag Artist "$T/photo.jpg")" ]
    [ ! -e "$OUT/created" ]
    [ "$(cat "$OUT/victim")" = "keep me" ]
    [ "$(find "$T" -type f | wc -l)" -eq 2 ]
}

@test "read-only files are reported as failed and left unchanged" {
    [ "$(id -u)" -ne 0 ] || skip "root can write read-only files"
    tagged_jpg "$T/photo.jpg"
    chmod 444 "$T/photo.jpg"
    clean --yes "$T/photo.jpg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed:"*"read-only file"* ]]
    [ "$(tag Artist "$T/photo.jpg")" = "Mario Rossi" ]
}

@test "files of unsupported types are reported as not cleaned" {
    printf '\000\001binary' > "$T/data.bin"
    printf 'plain\n' > "$T/LICENSE"
    clean -r --yes --report "$BATS_TEST_TMPDIR/r.txt" "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 file(s) have a type this tool cannot clean"* ]]
    grep -q 'data.bin \[timestamp; type not supported\]' "$BATS_TEST_TMPDIR/r.txt"
    grep -q 'LICENSE \[timestamp\]' "$BATS_TEST_TMPDIR/r.txt"
}

@test "only exact directory names are excluded" {
    mkdir -p "$T/node_modules" "$T/environment_photos" "$T/build"
    tagged_jpg "$T/node_modules/lib.jpg"
    tagged_jpg "$T/environment_photos/trip.jpg"
    tagged_jpg "$T/build/out.jpg"
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [ "$(tag Artist "$T/node_modules/lib.jpg")" = "Mario Rossi" ]
    [ "$(tag Artist "$T/build/out.jpg")" = "Mario Rossi" ]
    [ -z "$(tag Artist "$T/environment_photos/trip.jpg")" ]
    mkdir -p "$BATS_TEST_TMPDIR/build"
    tagged_jpg "$BATS_TEST_TMPDIR/build/inside.jpg"
    clean -r --yes "$BATS_TEST_TMPDIR/build"
    [ -z "$(tag Artist "$BATS_TEST_TMPDIR/build/inside.jpg")" ]
}

@test "removes author comments from code but not from Markdown" {
    printf '# Author: Mario Rossi\n# Date: 2024-01-01\nprint("ok")  # keep\n' > "$T/app.py"
    printf '# Date: 2024 roadmap\nText\n' > "$T/notes.md"
    clean -r --yes "$T"
    [ "$(cat "$T/app.py")" = 'print("ok")  # keep' ]
    [ "$(head -1 "$T/notes.md")" = "# Date: 2024 roadmap" ]
    printf '# Author: X\n' > "$T/again.py"
    clean --yes --keep-comments "$T/again.py"
    [ "$(cat "$T/again.py")" = "# Author: X" ]
}

@test "aggressive mode redacts values without deleting code" {
    cat > "$T/settings.py" <<'EOF'
password = "hunter2"
tokens = tokenizer(text)
contact = "mario.rossi@example.com"
DATA = "/home/mario/project/data.csv"
HOST = "192.168.1.20"
VERSION = "10.2.3.4.5"
python_version = "3.10.12"
EOF
    printf '{"api_key": "abc123", "name": "demo"}\n' > "$T/config.json"
    printf 'token: abc\nsecret_key = s3cr3t\n' > "$T/app.env"
    clean -r --yes --aggressive "$T"
    [ "$status" -eq 0 ]
    run cat "$T/settings.py"
    [[ "$output" == *'password = "[REDACTED]"'* ]]
    [[ "$output" == *'tokens = tokenizer(text)'* ]]
    [[ "$output" == *'[EMAIL_REDACTED]'* ]]
    [[ "$output" == *'/home/user/project/data.csv'* ]]
    [[ "$output" == *'[PRIVATE_IP]'* ]]
    [[ "$output" == *'10.2.3.4.5'* ]]
    [[ "$output" == *'3.10.12'* ]]
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["api_key"]=="[REDACTED]" and d["name"]=="demo"' "$T/config.json"
    [ "$(cat "$T/app.env")" = $'token: "[REDACTED]"\nsecret_key = "[REDACTED]"' ]
    cp "$T/settings.py" "$BATS_TEST_TMPDIR/before"
    clean -r --yes --aggressive "$T"
    cmp -s "$T/settings.py" "$BATS_TEST_TMPDIR/before"
}

@test "the audit flags sensitive data without copying it into the report" {
    printf 'write to mario.rossi@example.com\n' > "$T/readme.txt"
    clean -r --yes --report "$BATS_TEST_TMPDIR/report.txt" "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Audit: 1 text file(s)"* ]]
    grep -q "readme.txt: email" "$BATS_TEST_TMPDIR/report.txt"
    run ! grep -q "mario.rossi" "$BATS_TEST_TMPDIR/report.txt"
    clean -r --yes --strict "$T"
    [ "$status" -eq 4 ]
}

@test "the report is private, can include checksums and is never a symbolic link" {
    tagged_jpg "$T/photo.jpg"
    printf 'old\n' > "$BATS_TEST_TMPDIR/r.txt"
    chmod 644 "$BATS_TEST_TMPDIR/r.txt"
    clean -r --yes --checksums --report "$BATS_TEST_TMPDIR/r.txt" "$T"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/r.txt")" = "600" ]
    run ! grep -qx 'old' "$BATS_TEST_TMPDIR/r.txt"
    grep -q "^cleaned .*photo.jpg" "$BATS_TEST_TMPDIR/r.txt"
    grep -q "sha256 [0-9a-f]\{64\}" "$BATS_TEST_TMPDIR/r.txt"
    ln -s "$BATS_TEST_TMPDIR/r.txt" "$BATS_TEST_TMPDIR/link.txt"
    clean -r --yes --report "$BATS_TEST_TMPDIR/link.txt" "$T"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symbolic link"* ]]
}

@test "backups keep the originals outside the target" {
    tagged_jpg "$T/photo.jpg"
    clean -r --yes --backup-dir "$BATS_TEST_TMPDIR/bk" "$T"
    [ "$status" -eq 0 ]
    backup="$BATS_TEST_TMPDIR/bk$(cd "$T" && pwd -P)/photo.jpg"
    [ "$(tag Artist "$backup")" = "Mario Rossi" ]
    [ -z "$(tag Artist "$T/photo.jpg")" ]
    clean -r --yes --backup-dir "$T/inside" "$T"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside"* ]]
    [ ! -e "$T/inside" ]
}

@test "compressed backups replace the backup directory" {
    tagged_jpg "$T/photo.jpg"
    clean -r --yes --compress --backup-dir "$BATS_TEST_TMPDIR/bk" "$T"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/bk.tar.gz" ]
    [ ! -d "$BATS_TEST_TMPDIR/bk" ]
    tar -tzf "$BATS_TEST_TMPDIR/bk.tar.gz" | grep -q "photo.jpg"
    tagged_jpg "$T/again.jpg"
    clean -r --yes --compress --backup-dir ./-bk "$T"
    [ "$status" -eq 0 ]
    tar -tzf ./-bk.tar.gz | grep -q "again.jpg"
}

@test "dry run changes nothing" {
    tagged_jpg "$T/photo.jpg"
    before="$(stat -c %Y "$T/photo.jpg")"
    clean -r --dry-run "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would clean"*"photo.jpg"* ]]
    [ "$(tag Artist "$T/photo.jpg")" = "Mario Rossi" ]
    [ "$(stat -c %Y "$T/photo.jpg")" = "$before" ]
}

@test "no temporary files are left behind, in the target or in TMPDIR" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    tagged_jpg "$T/a.jpg"
    tagged_jpg "$T/b.jpg"
    printf 'not an image' > "$T/broken.png"
    clean -r --yes --parallel "$T"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed:"*"broken.png (exiftool)"* ]]
    [ "$(find "$T" -type f | wc -l)" -eq 3 ]
    [ -z "$(ls -A "$TMPDIR")" ]
    clean -r --dry-run "$T"
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "an interrupted run leaves no truncated file and no temporary folder" {
    command -v setsid >/dev/null 2>&1 || skip "setsid is not installed"
    tmp="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$tmp" "$BATS_TEST_TMPDIR/one"
    tagged_jpg "$BATS_TEST_TMPDIR/base.jpg"
    cp "$BATS_TEST_TMPDIR/base.jpg" "$BATS_TEST_TMPDIR/one/clean.jpg"
    clean --yes "$BATS_TEST_TMPDIR/one/clean.jpg"
    original="$(stat -c %s "$BATS_TEST_TMPDIR/base.jpg")"
    cleaned="$(stat -c %s "$BATS_TEST_TMPDIR/one/clean.jpg")"
    for i in $(seq 1 150); do cp "$BATS_TEST_TMPDIR/base.jpg" "$T/p$i.jpg"; done
    # A session of its own, so Ctrl-C can be sent to every process of the run, as a terminal does.
    TMPDIR="$tmp" setsid "$BASH_UNDER_TEST" "$SCRIPT" -r --yes --jobs 4 "$T" > /dev/null 2>&1 &
    pid=$!
    sleep 1
    kill -INT -- "-$pid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    wait "$pid" || true
    [ -z "$(ls -A "$tmp")" ]
    [ "$(find "$T" -type f | wc -l)" -eq 150 ]
    for f in "$T"/*.jpg; do
        size="$(stat -c %s "$f")"
        [ "$size" -eq "$original" ] || [ "$size" -eq "$cleaned" ]
    done
}

@test "timestamps are neutralised unless kept" {
    printf 'a\n' > "$T/a.txt"
    printf 'b\n' > "$T/b.txt"
    clean --yes "$T/a.txt"
    clean --yes --keep-timestamps "$T/b.txt"
    [ "$(mtime_year "$T/a.txt")" = "2000" ]
    [ "$(mtime_year "$T/b.txt")" != "2000" ]
}

@test "PDF: properties and their old revision are removed; text, links and bookmarks are kept" {
    command -v qpdf >/dev/null 2>&1 || skip "qpdf is not installed"
    cp "$FIX/link.pdf" "$T/doc.pdf"
    clean --yes --report "$BATS_TEST_TMPDIR/r.txt" "$T/doc.pdf"
    [ "$status" -eq 0 ]
    [ -z "$(tag Author "$T/doc.pdf")" ]
    grep -q "doc.pdf \[exiftool+qpdf\]" "$BATS_TEST_TMPDIR/r.txt"
    [ "$(ls -A "$T")" = "doc.pdf" ]
    qpdf --qdf --object-streams=disable "$T/doc.pdf" "$BATS_TEST_TMPDIR/doc.qdf" || [ "$?" -eq 3 ]
    run ! grep -q "Mario Rossi" "$BATS_TEST_TMPDIR/doc.qdf"
    grep -q "Hello reader" "$BATS_TEST_TMPDIR/doc.qdf"
    grep -q "https://example.com/" "$BATS_TEST_TMPDIR/doc.qdf"
    grep -q "Chapter one" "$BATS_TEST_TMPDIR/doc.qdf"
    [ "$(qpdf --show-npages "$T/doc.pdf")" = "1" ]
}

@test "PDF without qpdf: the old values stay recoverable and the summary says so" {
    cp "$FIX/native-metadata.pdf" "$T/doc.pdf"
    PATH="$(path_without qpdf)" run "$BASH_UNDER_TEST" "$SCRIPT" --yes --report "$BATS_TEST_TMPDIR/r.txt" "$T/doc.pdf"
    [ "$status" -eq 0 ]
    [ -z "$(tag Author "$T/doc.pdf")" ]
    grep -q "Mario Rossi" "$T/doc.pdf"   # hidden in an earlier revision, not removed
    grep -q "recoverable: install qpdf" "$BATS_TEST_TMPDIR/r.txt"
    [[ "$output" == *"old values can still be recovered"* ]]
}

@test "types that need mat2 are reported, not faked, when it is missing" {
    printf 'PK fake docx' > "$T/letter.docx"
    PATH="$(path_without mat2)" run "$BASH_UNDER_TEST" "$SCRIPT" --yes --report "$BATS_TEST_TMPDIR/r.txt" "$T/letter.docx"
    [ "$status" -eq 0 ]
    grep -q "install mat2" "$BATS_TEST_TMPDIR/r.txt"
    [[ "$output" == *"Cleaned: 0"* ]]
    [[ "$output" == *"kept their metadata"*"Install mat2"* ]]
}

@test "mat2 cleans office documents on a private copy: hard links kept, planted links ignored" {
    command -v mat2 >/dev/null 2>&1 || skip "mat2 is not installed"
    make_docx "$T/letter.docx"
    chmod 640 "$T/letter.docx"
    ln "$T/letter.docx" "$BATS_TEST_TMPDIR/link.docx"
    printf 'keep me\n' > "$OUT/victim"
    ln -s ../outside/victim "$T/letter.cleaned.docx"   # mat2's output file name
    clean -r --yes "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 1"* ]]
    run ! zip_contains "$BATS_TEST_TMPDIR/link.docx" "Mario Rossi"
    zip_contains "$T/letter.docx" "Hello reader"
    [ "$(cat "$OUT/victim")" = "keep me" ]
    [ "$(stat -c '%a' "$T/letter.docx")" = "640" ]
    [ "$(find "$T" -type f | wc -l)" -eq 1 ]
}

@test "mat2 failures are reported and leave the file unchanged" {
    command -v mat2 >/dev/null 2>&1 || skip "mat2 is not installed"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").writestr("app.py", "print(1)\n")' "$T/code.zip"
    cp "$T/code.zip" "$BATS_TEST_TMPDIR/before.zip"
    clean --yes --keep-timestamps "$T/code.zip"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed:"*"code.zip (mat2)"* ]]
    cmp -s "$T/code.zip" "$BATS_TEST_TMPDIR/before.zip"
}

@test "dry runs and cancelled runs leave no backup directory behind" {
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    tagged_jpg "$T/photo.jpg"
    clean -r --dry-run --backup "$T"
    [ "$status" -eq 0 ]
    clean -r --backup "$T" < /dev/null
    [ "$status" -eq 3 ]
    clean -r --backup --backup-dir "$T/inside" "$T"
    [ "$status" -eq 1 ]
    [ -z "$(find "$XDG_STATE_HOME" "$T" -name 'backup-*' -o -name inside)" ]
    clean -r --yes --backup "$T"
    [ "$status" -eq 0 ]
    [ -n "$(find "$XDG_STATE_HOME" -name 'photo.jpg')" ]
}

@test "refuses the file system root and the home directory" {
    clean --dry-run /
    [ "$status" -eq 1 ]
    [[ "$output" == *"whole file system"* ]]
    clean --dry-run "$HOME"
    [ "$status" -eq 1 ]
}

@test "sanitize-git removes remotes, local identity and stored credentials" {
    git init --quiet "$T/repo"
    git -C "$T/repo" remote add origin https://github.com/mario/private.git
    git -C "$T/repo" config user.email mario@example.com
    git -C "$T/repo" config http.https://github.com/.extraheader "AUTHORIZATION: basic c2VjcmV0"
    git -C "$T/repo" config credential.helper store
    git -C "$T/repo" config core.autocrlf false
    clean --yes --sanitize-git --backup-dir "$BATS_TEST_TMPDIR/bk" "$T/repo"
    [ "$status" -eq 0 ]
    [ -z "$(git -C "$T/repo" remote)" ]
    run ! git -C "$T/repo" config --local user.email
    run ! grep -qiE 'authorization|helper' "$T/repo/.git/config"
    [ "$(git -C "$T/repo" config --local core.autocrlf)" = "false" ]
    grep -q "AUTHORIZATION" "$BATS_TEST_TMPDIR/bk$(cd "$T/repo" && pwd -P)/.git/config"
}

@test "sanitize-git never changes a parent repository when .git is broken" {
    git init --quiet "$T"
    git -C "$T" remote add origin https://github.com/mario/parent.git
    mkdir -p "$T/child/.git"
    printf '[user]\n\temail = x@example.com\n' > "$T/child/.git/config"
    clean --yes --sanitize-git --backup-dir "$BATS_TEST_TMPDIR/bk" "$T/child"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a valid Git repository"* ]]
    [ "$(git -C "$T" remote)" = "origin" ]
}

@test "parallel workers run when the script is started through a symbolic link" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/bin/mclean"
    tagged_jpg "$T/a.jpg"
    tagged_jpg "$T/b.jpg"
    run "$BASH_UNDER_TEST" "$BATS_TEST_TMPDIR/bin/mclean" -r --yes --parallel "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 2"* ]]
}

@test "--jobs alone turns on parallel mode" {
    tagged_jpg "$T/a.jpg"
    tagged_jpg "$T/b.jpg"
    clean -r --yes --verbose --jobs 2 "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 2"* ]]
    [[ "$output" == *"[VERBOSE] Parallel mode: 2 workers"* ]]
}

@test "relative targets such as . work from inside the folder" {
    tagged_jpg "$T/photo one.jpg"
    cd "$T" || return 1
    clean -r --yes .
    [ "$status" -eq 0 ]
    [ -z "$(tag Artist "$T/photo one.jpg")" ]
}

@test "a single target starting with a dash is a file, not an option" {
    cd "$T" || return 1
    tagged_jpg "./-all=.jpg"
    clean --yes -- "-all=.jpg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 1"* ]]
    [ -z "$(tag Artist "./-all=.jpg")" ]
}
