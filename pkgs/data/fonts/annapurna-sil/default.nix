# when changing this expression convert it from 'fetchzip' to 'stdenvNoCC.mkDerivation'
{ lib, fetchzip }:

let
  version = "1.204";
  name = "annapurna-sil-${version}";
in
  (fetchzip rec {
    inherit name;

    url = "https://software.sil.org/downloads/r/annapurna/AnnapurnaSIL-${version}.zip";

    sha256 = "sha256-kVeP9ZX8H+Wn6jzmH1UQvUKY6vJjadMTdEusS7LodFM=";

    meta = with lib; {
      homepage = "https://software.sil.org/annapurna";
      description = "Unicode-based font family with broad support for writing systems that use the Devanagari script";
      longDescription = ''
        Annapurna SIL is a Unicode-based font family with broad support for writing systems that use the Devanagari script. Inspired by traditional calligraphic forms, the design is intended to be highly readable, reasonably compact, and visually attractive.
      '';
      license = licenses.ofl;
      platforms = platforms.all;
      maintainers = [ maintainers.kmein ];
    };
  }).overrideAttrs (_: {
    postFetch = ''
      mkdir -p $out/share/{doc,fonts}
      unzip -j $downloadedFile \*.ttf -d $out/share/fonts/truetype
      unzip -j $downloadedFile \*OFL.txt \*OFL-FAQ.txt \*README.txt \*FONTLOG.txt -d "$out/share/doc/${name}"
    '';
  })
