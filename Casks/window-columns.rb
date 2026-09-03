cask "window-columns" do
  version "0.1.0-beta.2"
  sha256 "e27fa4a50e7de7293ddb6efb3130d2bf0a53005c881840d9529aec0ac893904c"

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
