def keep_mac_file_drags(profile):
    """Dropping a file moves it without a menu, and a folder springs open while a file is held over it."""
    wanted = (
        ("kdeglobals", "[KDE]", "DndBehavior", "MoveIfSameDevice"),
        ("dolphinrc", "[General]", "AutoExpandFolders", "true"),
    )
    for name, group, key, value in wanted:
        path = profile / name
        lines = path.read_text().splitlines()
        setting = f"{key}={value}"
        if group not in lines:
            lines += ["", group, setting]
        else:
            start = lines.index(group) + 1
            end = next((i for i in range(start, len(lines)) if lines[i].startswith("[")), len(lines))
            found = [i for i in range(start, end) if lines[i].startswith(key + "=")]
            if found:
                if lines[found[0]] == setting:
                    continue
                lines[found[0]] = setting
            else:
                lines.insert(start, setting)
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write("\n".join(lines) + "\n")
        try:
            temporary.chmod(path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
