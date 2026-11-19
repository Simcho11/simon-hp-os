# HP-OS User Guide

`hp-os-user-guide.pdf` is put on every account's desktop (once; later editions replace it only if it's
unchanged) and kept at `~/.local/share/hp-os/HP-OS User Guide.pdf`, which Settings › Welcome opens
(goran/desktop/hp-snap/home.nix).

To change it, edit `content.py` (the chapters) or `manual.css` (the look), then rebuild on the publishing
laptop and copy the result over the PDF here:

    python3 -I build.py && cp "HP-OS User Guide.pdf" hp-os-user-guide.pdf

`build.py` lays the guide out as HTML, prints it to PDF with Google Chrome, and repeats until the page
numbers in the contents settle. The screenshots in `img/` come from a hidden test desktop.
