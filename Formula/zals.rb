# Source template for the zals Homebrew formula.
#
# The release workflow renders this file (substituting the __PLACEHOLDER__
# tokens with the released version and the SHA-256 of each archive) and pushes
# the result to the tap repository (default: kksat/homebrew-tap). Edit this
# template, not the rendered copy in the tap.
class Zals < Formula
  desc "Zig Ansible Language Server"
  homepage "https://github.com/kksat/zals"
  version "__VERSION__"
  license "GPL-3.0-only"

  on_macos do
    on_arm do
      url "https://github.com/kksat/zals/releases/download/v__VERSION__/zals-__VERSION__-aarch64-macos.tar.gz"
      sha256 "__SHA256_AARCH64_MACOS__"
    end
    on_intel do
      url "https://github.com/kksat/zals/releases/download/v__VERSION__/zals-__VERSION__-x86_64-macos.tar.gz"
      sha256 "__SHA256_X86_64_MACOS__"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/kksat/zals/releases/download/v__VERSION__/zals-__VERSION__-aarch64-linux.tar.gz"
      sha256 "__SHA256_AARCH64_LINUX__"
    end
    on_intel do
      url "https://github.com/kksat/zals/releases/download/v__VERSION__/zals-__VERSION__-x86_64-linux.tar.gz"
      sha256 "__SHA256_X86_64_LINUX__"
    end
  end

  def install
    bin.install "zals"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/zals --version 2>&1")
  end
end