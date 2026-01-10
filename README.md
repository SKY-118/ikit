# iKit

A comprehensive macOS automation toolkit (v2.3.0) written in Swift.

## Features

- **Notes**: Smart sync Apple Notes to Markdown files, CRUD operations via AppleScript.
- **Tasks**: Manage Apple Reminders (list, new, complete, delete).
- **Calendar**: Manage Apple Calendar events.
- **Contacts**: Search Apple Contacts.
- **Photos**: List recent photos/screenshots and perform OCR on images using Vision framework.
- **Shortcuts**: List and run macOS Shortcuts.

## Installation

```bash
make install
```

This will install the `ikit` binary to `~/.local/bin`.

## Usage

```bash
ikit --help
```

### Note Sync
To sync Apple Notes to a local directory:
```bash
ikit note sync /path/to/notes
```

### Photo OCR
Perform OCR on the last 5 screenshots:
```bash
ikit photo ocr --screenshots --last 5
```
