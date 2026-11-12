#!/usr/bin/env python3
"""Writes THIRD-PARTY-NOTICES.txt for the Windows release from what windows/scripts/collect-notices.ps1 gathered.

    scripts/windows-notices.py <notices-src dir> <out file>

Every file in the publish folder must come from OpenMusic itself or from one of the collected packages (matched by
file name); the script stops and lists any file it can't trace, so a new dependency can't ship without its notice.
Each package that contributes a file is listed with its license, and every license and notice text it ships is
included once.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

# Files OpenMusic builds itself (the app, its libraries, compiled XAML, resources). Its own assets are the files in
# windows/src/OpenMusic.App/Assets, checked by name below; anything else under Assets\ must be traced to a package.
OWN = re.compile(r"^(OpenMusic(\.[A-Za-z.]+)?\.(dll|exe|pri|json|xbf)|.*\.xbf)$", re.IGNORECASE)
OWN_ASSETS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "windows", "src", "OpenMusic.App", "Assets")
OWN_ASSETS = {"assets\\" + name.lower() for name in os.listdir(OWN_ASSETS_DIR)} if os.path.isdir(OWN_ASSETS_DIR) else set()
NOTICE_NAME = re.compile(r"(?i)(licen[cs]e|notice|copying)")

# Restored or downloaded but never copied into the publish: build tools, and runtime packs for other architectures
# or for frameworks the app doesn't use (ASP.NET Core, WPF/Windows Forms). A published file only these hold is
# reported as untraced.
NOT_SHIPPED = re.compile(
    r"^(Microsoft\.NET\.ILLink\.Tasks|Microsoft\.NETCore\.App\.Crossgen2\.[^@]+|Microsoft\.Windows\.SDK\.BuildTools(\.MSIX)?"
    r"|Microsoft\.AspNetCore\.App\.Runtime\.[^@]+|Microsoft\.WindowsDesktop\.App\.Runtime\.[^@]+)@"
    r"|\.win-(arm64|arm64ec|x86)@")

# Components whose package carries no license file: the notice to print for them.
WINDOWS_SDK_NOTICE = """The Windows SDK for .NET projection (Microsoft.Windows.SDK.NET.dll) is part of the Windows SDK,
(c) Microsoft Corporation, and is distributed under the Windows SDK license terms: https://aka.ms/WinSDKLicenseURL

WinRT.Runtime.dll is part of C#/WinRT (https://github.com/microsoft/CsWinRT):

MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
NO_FILE_NOTICES = {"microsoft.windows.sdk.net.ref": WINDOWS_SDK_NOTICE}


def read_text(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    for enc in ("utf-8-sig", "utf-16", "cp1252"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    return text.replace("\r\n", "\n").strip() + "\n"


def read_lines(path):
    return [line.strip() for line in read_text(path).splitlines() if line.strip()]


def nuspec_info(directory):
    """(title, license expression or URL, copyright, declared license file or None) from the package's .nuspec."""
    for name in os.listdir(directory):
        if not name.endswith(".nuspec"):
            continue
        root = ET.parse(os.path.join(directory, name)).getroot()
        meta = next(child for child in root if child.tag.endswith("metadata"))
        values = {child.tag.split("}")[-1]: (child.text or "").strip() for child in meta}
        lic = next((child for child in meta if child.tag.endswith("license")), None)
        license_text, license_file = values.get("licenseUrl", ""), None
        if lic is not None and lic.get("type") == "expression":
            license_text = (lic.text or "").strip()
        elif lic is not None and lic.get("type") == "file":
            license_text = "see the license text below"
            license_file = re.sub(r"[\\/]", "__", (lic.text or "").strip())
        return values.get("title") or values.get("id", ""), license_text, values.get("copyright", ""), license_file
    return "", "", "", None


def main(src, out_path):
    publish = read_lines(os.path.join(src, "publish-files.txt"))
    packages = sorted(d for d in os.listdir(src) if os.path.isdir(os.path.join(src, d)) and not NOT_SHIPPED.search(d))
    owner = {}
    for package in packages:
        for rel in read_lines(os.path.join(src, package, "files.txt")):
            owner.setdefault(re.split(r"[\\/!]", rel)[-1].lower(), set()).add(package)

    contributed, untraced = {}, []
    for rel in publish:
        name = rel.split("\\")[-1].lower()
        if OWN.match(rel) or rel.lower() in OWN_ASSETS:
            continue
        if name not in owner:
            untraced.append(rel)
            continue
        for package in owner[name]:
            contributed.setdefault(package, []).append(rel)
    if untraced:
        print("windows-notices: files in the publish that no package accounts for (add their notice):", file=sys.stderr)
        for rel in untraced:
            print("  " + rel, file=sys.stderr)
        return 1

    lines = [
        "OpenMusic for Windows: third-party notices",
        "",
        "OpenMusic is released under the MIT License (LICENSE, next to this file). The OpenMusic folder also contains",
        "the components below, each under its own license. This file was written by scripts/package-windows.sh from",
        "the packages this build was published from.",
        "",
        "COMPONENTS",
        "",
    ]
    texts = {}  # license or notice text -> the packages that ship it
    for package in sorted(contributed, key=str.lower):
        directory = os.path.join(src, package)
        package_id, version = package.split("@", 1)
        title, license_text, copyright_text, license_file = nuspec_info(directory)
        shipped = sorted({f for f in os.listdir(directory) if NOTICE_NAME.search(f) and not f.endswith(".nuspec")})
        if license_file and license_file.lower() not in {f.lower() for f in shipped}:
            print(f"windows-notices: {package} declares license file {license_file!r}, which wasn't collected", file=sys.stderr)
            return 1
        lines.append(f"- {package_id} {version}" + (f" ({title})" if title and title != package_id else ""))
        if copyright_text:
            lines.append(f"  {copyright_text}")
        lines.append(f"  License: {license_text or 'see below'}. {len(contributed[package])} file(s) in this folder.")
        for name in shipped:
            texts.setdefault(read_text(os.path.join(directory, name)), []).append(f"{package_id} {version}: {name}")
        if not shipped and package_id.lower() in NO_FILE_NOTICES:
            texts.setdefault(NO_FILE_NOTICES[package_id.lower()], []).append(f"{package_id} {version}")
        elif not shipped:
            print(f"windows-notices: {package} ships no license file and has no notice here", file=sys.stderr)
            return 1
    lines += ["", "LICENSE AND NOTICE TEXTS", ""]
    for text, sources in texts.items():
        lines.append("=" * 100)
        lines += [f"From {source}" for source in sources]
        lines.append("=" * 100)
        lines.append("")
        lines.append(text)
    with open(out_path, "w", encoding="utf-8", newline="\r\n") as fh:
        fh.write("\n".join(lines))
    print(f"windows-notices: {len(contributed)} components, {len(texts)} license and notice texts, "
          f"{len(publish)} published files traced")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
