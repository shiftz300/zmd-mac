#!/usr/bin/env python3
"""Build a native Installer product with direct per-user CN/global setup scripts."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parents[1]
INSTALL_ROOT = "/Library/Application Support/zmd-mac"
VERSION = "0.5.5"


def build(distribution, output):
    distribution = distribution.resolve()
    output = output.absolute()
    if output.exists() or output.with_suffix(".pkg.sha256").exists():
        raise SystemExit(f"Refusing to overwrite: {output}")
    subprocess.run([str(distribution / "zmd"), "verify"], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zmd-pkg-", dir=output.parent) as temporary:
        work = Path(temporary)
        root = work / "root"
        root.mkdir()
        # Only the verified distribution is packaged, never a game application.
        for name in ("zmd", "payload", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "docs", "licenses"):
            subprocess.run(["cp", "-cR", str(distribution / name), str(root / name)], check=True)
        # Empty component list prevents Installer from relocating or treating the
        # nested AppTemplate as an independently upgradable game application.
        components = work / "components.plist"
        components.write_bytes(plistlib.dumps([]))
        common_scripts = work / "common-scripts"
        common_scripts.mkdir()
        shutil.copy2(PROJECT / "scripts/pkg-user.sh", common_scripts / "pkg-user.sh")
        preinstall = common_scripts / "preinstall"
        preinstall.write_text('''#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/pkg-user.sh"
zmd_pkg_user "$@"
zmd_as_user /usr/bin/arch -x86_64 /usr/bin/true || {
    echo '请先安装 Rosetta 2，再重新运行安装包。' >&2; exit 1;
}
''')
        preinstall.chmod(0o755)
        subprocess.run(["pkgbuild", "--root", str(root), "--component-plist", str(components),
                        "--scripts", str(common_scripts), "--install-location", INSTALL_ROOT,
                        "--identifier", "local.zmdmac.installer.runtime", "--version", VERSION,
                        str(work / "runtime.pkg")], check=True)

        for region in ("cn", "global"):
            scripts = work / (region + "-scripts")
            scripts.mkdir()
            shutil.copy2(PROJECT / "scripts/pkg-user.sh", scripts / "pkg-user.sh")
            postinstall = scripts / "install-region"
            postinstall.write_text('''#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/pkg-user.sh"
zmd_pkg_user "$@"
zmd_as_user '/Library/Application Support/zmd-mac/zmd' install --region ''' + region + ''' --desktop
''')
            postinstall.chmod(0o755)
            # A non-executable receipt bundle allows Apple's supported
            # component-script timeout for slower official downloads.
            region_root = work / (region + "-root")
            bundle_path = "Regions/" + region + ".bundle"
            bundle = region_root / bundle_path / "Contents"
            bundle.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "local.zmdmac.installer.receipt." + region,
                "CFBundleVersion": VERSION, "CFBundlePackageType": "BNDL",
            }))
            region_components = work / (region + "-components.plist")
            region_components.write_bytes(plistlib.dumps([{
                "RootRelativeBundlePath": bundle_path,
                "BundleIsRelocatable": False,
                "BundleIsVersionChecked": False,
                "BundleHasStrictIdentifier": True,
                "BundleOverwriteAction": "upgrade",
                "BundlePostInstallScriptPath": "install-region",
                "BundleInstallScriptTimeout": 1800,
            }]))
            subprocess.run(["pkgbuild", "--root", str(region_root),
                            "--component-plist", str(region_components), "--scripts", str(scripts),
                            "--install-location", INSTALL_ROOT,
                            "--identifier", "local.zmdmac.installer." + region,
                            "--version", VERSION, str(work / (region + ".pkg"))], check=True)

        resources = work / "resources"
        resources.mkdir()
        (resources / "welcome.html").write_text('''<!doctype html><meta charset="utf-8">
<h2>终末地 · macOS</h2><p>在「安装类型 → 自定」选择国服或 Global，也可以同时安装两服。</p>
<p>安装脚本将下载对应官方启动器，在当前登录用户的「应用程序」目录生成独立应用，并创建桌面入口。</p>
<p>需要 Apple Silicon、macOS 27、Rosetta 2 和网络。游戏资源由官方启动器下载。</p>
<p>已有同名应用时停止该项安装，不覆盖游戏或账号。Global 尚未完成游戏内兼容性验证。</p>''')
        (resources / "conclusion.html").write_text('''<!doctype html><meta charset="utf-8">
<h2>安装完成</h2><p>从桌面或个人「应用程序」目录打开「鹰角启动器」／「GRYPHLINK」，
在官方启动器中下载并开始游戏。</p><p>运行设置可从左上角应用菜单打开。</p>''')
        doc = ET.Element("installer-gui-script", {"minSpecVersion": "2"})
        ET.SubElement(doc, "title").text = "终末地"
        ET.SubElement(doc, "welcome", {"file": "welcome.html", "mime-type": "text/html"})
        ET.SubElement(doc, "conclusion", {"file": "conclusion.html", "mime-type": "text/html"})
        ET.SubElement(doc, "options", {"customize": "always", "require-scripts": "true", "hostArchitectures": "arm64"})
        ET.SubElement(doc, "domains", {"enable_anywhere": "false", "enable_currentUserHome": "false", "enable_localSystem": "true"})
        volume = ET.SubElement(doc, "volume-check")
        ET.SubElement(ET.SubElement(volume, "allowed-os-versions"), "os-version", {"min": "27.0"})
        outline = ET.SubElement(doc, "choices-outline")
        for region in ("runtime", "cn", "global"):
            ET.SubElement(outline, "line", {"choice": region})
        titles = {"runtime": "运行环境", "cn": "国服", "global": "Global · GRYPHLINK"}
        for region in ("runtime", "cn", "global"):
            attributes = {"id": region, "title": titles[region], "start_selected": "false" if region == "global" else "true"}
            if region == "runtime":
                attributes.update({"visible": "false", "enabled": "false", "selected": "true"})
            else:
                attributes["description"] = "安装到当前用户的 ~/Applications/" + ("鹰角启动器" if region == "cn" else "GRYPHLINK") + ".app；已有应用不会覆盖。"
            choice = ET.SubElement(doc, "choice", attributes)
            identifier = "local.zmdmac.installer." + region
            ET.SubElement(choice, "pkg-ref", {"id": identifier})
            ET.SubElement(doc, "pkg-ref", {"id": identifier, "version": VERSION, "onConclusion": "none"}).text = region + ".pkg"
        xml = work / "Distribution.xml"
        ET.ElementTree(doc).write(xml, encoding="utf-8", xml_declaration=True)
        subprocess.run(["productbuild", "--distribution", str(xml), "--package-path", str(work),
                        "--resources", str(resources), str(output)], check=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".pkg.sha256").write_text(digest + "  " + output.name + "\n")
    print(f"Installer: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--distribution", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.distribution, args.output)
