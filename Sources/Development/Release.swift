import Foundation

let releaseAssets = [
  "zmd-mac-macos-arm64.pkg", "zmd-mac-macos-arm64.zip", "third-party-sources.tar.gz",
]
func verifyRelease(_ tag: String, _ directory: URL) throws -> Bool {
  try require(
    try !matches("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$", tag).isEmpty,
    "Expected version tag")
  for name in releaseAssets {
    let asset = directory.at(name)
    let sum = directory.at(name + ".sha256")
    try require(
      regular(asset) && !asset.link
        && (try fm.attributesOfItem(atPath: asset.path)[.size] as! NSNumber).intValue > 0,
      "Missing or invalid asset: \(name)")
    try require(
      !sum.link
        && (try sum.text.trimmingCharacters(in: .whitespacesAndNewlines)) == digest(asset) + "  "
          + name,
      "Checksum mismatch: \(name)")
  }
  let raw = try command(
    [
      "unzip", "-p", directory.at("zmd-mac-macos-arm64.zip").path,
      "zmd-mac/payload/AppTemplate.app/Contents/Info.plist",
    ], capture: true
  ).output
  let meta =
    try PropertyListSerialization.propertyList(from: Data(raw.utf8), format: nil) as! [String: Any]
  try require(
    meta["CFBundleShortVersionString"] as? String
      == String(tag.dropFirst()).components(separatedBy: "-")[0], "Tag differs from app version")
  return tag.contains("-")
}
typealias ReleaseRunner = ([String], Bool) throws -> CommandResult
func publishRelease(
  _ tag: String, _ directory: URL, checkOnly: Bool, repository: String? = env["GITHUB_REPOSITORY"],
  commit: String? = env["GITHUB_SHA"],
  runner: ReleaseRunner = { try command($0, capture: true, allowFailure: $1) }
) throws {
  let prerelease = try verifyRelease(tag, directory)
  if checkOnly {
    print("PASS: release assets, checksums and app version")
    return
  }
  guard let repository, let commit else {
    throw Failure("GITHUB_REPOSITORY and GITHUB_SHA are required")
  }
  let prefix = ["gh", "release"]
  let view = try runner(
    prefix + ["view", tag, "--repo", repository, "--json", "isDraft,targetCommitish"], true)
  if view.status == 0 {
    let existing = try JSONSerialization.jsonObject(with: Data(view.output.utf8)) as! [String: Any]
    try require(
      existing["isDraft"] as? Bool == true && existing["targetCommitish"] as? String == commit,
      "Refusing to modify published release or unrelated draft")
  } else {
    var args = [
      "create", tag, "--repo", repository, "--verify-tag", "--target", commit, "--title",
      "zmd-mac " + tag, "--draft", "--generate-notes", "--notes",
      "Apple Silicon / macOS 27 / Rosetta 2。PKG 可选择国服或 Global；ZIP 用于命令行安装。附第三方源码；尚未公证。",
    ]
    if prerelease { args.append("--prerelease") }
    _ = try runner(prefix + args, false)
  }
  _ = try runner(
    prefix + ["upload", tag, "--repo", repository, "--clobber"]
      + releaseAssets.map { directory.at($0).path }, false)
  let result = try runner(prefix + ["view", tag, "--repo", repository, "--json", "assets"], false)
  let uploaded = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: Any]
  var remote: [String: Int] = [:]
  var expected: [String: Int] = [:]
  for asset in uploaded["assets"] as! [[String: Any]] {
    remote[asset["name"] as! String] = (asset["size"] as! NSNumber).intValue
  }
  for name in releaseAssets {
    expected[name] =
      (try fm.attributesOfItem(atPath: directory.at(name).path)[.size] as! NSNumber).intValue
  }
  try require(remote == expected, "Incomplete/unexpected draft assets; leaving unpublished")
  _ = try runner(
    prefix + [
      "edit", tag, "--repo", repository, "--draft=false", "--prerelease=\(prerelease)",
      "--latest=\(!prerelease)",
    ], false)
}
