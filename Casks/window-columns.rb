cask "window-columns" do
  version "0.1.0-beta.4"
  sha256 "416cea09e05358ce19ccd834d6d4afc8922a5c1806d1313d323402a946cca9b0"

  url "https://github.com/maskilx/window-columns/releases/download/v#{version}/Window-Columns-v#{version}-macos-arm64.zip"
  name "Window Columns"
  desc "Arrange app windows as connected full-height columns"
  homepage "https://github.com/maskilx/window-columns"

  livecheck do
    skip "Beta cask is updated manually with each tagged prerelease"
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  postflight do
    system_command "xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Window Columns.app"]
  end

  app "Window Columns.app"

  caveats <<~EOS
    Window Columns is an ad-hoc signed, unnotarised public beta. The cask automatically
    removes the quarantine attribute so the app opens without Gatekeeper warnings.
    If you encounter any issues on first launch, run:

      xattr -cr "/Applications/Window Columns.app"

    Verify the release checksum before running the app.
  EOS
end
