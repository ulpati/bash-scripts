# Changelog

All notable changes to the three tools. Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0 (2026-10-04)

First public release.

### Metadata Cleaner

- Removes EXIF, XMP, IPTC and GPS data, camera tags and video recording
  dates with ExifTool, without re-encoding images or videos.
- Removes PDF document properties and rebuilds the file with qpdf, so the
  old values cannot be recovered.
- Cleans office documents, EPUB, ZIP, torrent and audio files with mat2.
- Cleans Jupyter notebooks and author comments in code; optional redaction
  of secrets, e-mail addresses, home paths and private IP addresses.
- Audit of text files, private reports with checksums, backups, parallel
  mode and `--sanitize-git`.

### Publish Repository

- Initialises a repository, lists the pending changes, scans them for
  secrets and commits after confirmation.
- Pushes to any remote, or creates a GitHub repository with `gh`; remote URLs
  and names are validated; dry run.

### Life Game

- Goals, daily tasks and weekly missions with points, levels and badges.
- Study mode with Pomodoro timer, flashcards and study hours; import and
  sync of Markdown plans.
- Private plain-text data file; one profile per data folder.
