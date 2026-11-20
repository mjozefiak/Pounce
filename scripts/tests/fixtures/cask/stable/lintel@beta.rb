cask "lintel@beta" do
  version "0.1.0"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  url "https://github.com/mjozefiak/lintel/releases/download/v#{version}/Lintel.dmg",
      verified: "github.com/mjozefiak/lintel/"
  name "Lintel"
  desc "Launcher with file search, clipboard history, dictation and meeting notes"
  homepage "https://lintelapp.com/"

  livecheck do
    url "https://lintelapp.com/appcast.xml"
    strategy :sparkle do |items|
      items.map(&:short_version)
    end
  end

  auto_updates true
  conflicts_with cask: "lintel"
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Lintel.app"

  zap trash: [
    "~/Library/Application Support/Lintel",
    "~/Library/Caches/com.lintelapp.Lintel",
    "~/Library/Caches/Lintel",
    "~/Library/HTTPStorages/com.lintelapp.Lintel",
    "~/Library/Preferences/com.lintelapp.Lintel.plist",
    "~/Library/Saved Application State/com.lintelapp.Lintel.savedState",
    "~/Library/WebKit/com.lintelapp.Lintel",
  ]
end
