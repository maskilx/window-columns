cask "window-columns" do
  version "0.1.0-beta.1"
  sha256 "101e6ca5eed0d5924cddb369406ce9e317bf4a4da3f3fe52d37d1382f0633cc4"

  url "https://github.com/maskilx/window-columns/releases/download/v#{version}/Window-Columns-v#{version}-macos-arm64.zip"
  name "Window Columns"
  desc "Arrange app windows as connected full-height columns"
  homepage "https://github.com/maskilx/window-columns"

  livecheck do
    skip "Beta cask is updated manually with each tagged prerelease"
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Window Columns.app"

  caveats <<~EOS
    Window Columns is an ad-hoc signed, unnotarised public beta. If Gatekeeper
    blocks the first launch, Control-click the app in /Applications and choose
    Open, or run:

      xattr -cr "/Applications/Window Columns.app"

    Verify the release checksum before bypassing Gatekeeper.
  EOS
end
