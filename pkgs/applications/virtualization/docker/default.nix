{ lib, callPackage, fetchFromGitHub }:

rec {
  dockerGen = {
      version, rev, sha256
      , moby-src
      , runcRev, runcSha256
      , containerdRev, containerdSha256
      , tiniRev, tiniSha256, buildxSupport ? true, composeSupport ? true
      # package dependencies
      , stdenv, fetchFromGitHub, fetchpatch, buildGoPackage
      , makeWrapper, installShellFiles, pkg-config, glibc
      , go-md2man, go, containerd, runc, docker-proxy, tini, libtool
      , sqlite, iproute2, docker-buildx, docker-compose
      , iptables, e2fsprogs, xz, util-linux, xfsprogs, git
      , procps, rootlesskit, slirp4netns, fuse-overlayfs, nixosTests
      , clientOnly ? !stdenv.isLinux, symlinkJoin
      , withSystemd ? stdenv.isLinux, systemd
      , withBtrfs ? stdenv.isLinux, btrfs-progs
      , withLvm ? stdenv.isLinux, lvm2
      , withSeccomp ? stdenv.isLinux, libseccomp
    }:
  let
    docker-runc = runc.overrideAttrs (oldAttrs: {
      pname = "docker-runc";
      inherit version;

      src = fetchFromGitHub {
        owner = "opencontainers";
        repo = "runc";
        rev = runcRev;
        sha256 = runcSha256;
      };

      # docker/runc already include these patches / are not applicable
      patches = [];
    });

    docker-containerd = containerd.overrideAttrs (oldAttrs: {
      pname = "docker-containerd";
      inherit version;

      src = fetchFromGitHub {
        owner = "containerd";
        repo = "containerd";
        rev = containerdRev;
        sha256 = containerdSha256;
      };

      buildInputs = oldAttrs.buildInputs
        ++ lib.optionals withSeccomp [ libseccomp ];
    });

    docker-tini = tini.overrideAttrs (oldAttrs: {
      pname = "docker-init";
      inherit version;

      src = fetchFromGitHub {
        owner = "krallin";
        repo = "tini";
        rev = tiniRev;
        sha256 = tiniSha256;
      };

      # Do not remove static from make files as we want a static binary
      postPatch = "";

      buildInputs = [ glibc glibc.static ];

      NIX_CFLAGS_COMPILE = "-DMINIMAL=ON";
    });

    moby = buildGoPackage (lib.optionalAttrs stdenv.isLinux rec {
      pname = "moby";
      inherit version;

      src = moby-src;

      goPackagePath = "github.com/docker/docker";

      nativeBuildInputs = [ makeWrapper pkg-config go-md2man go libtool installShellFiles ];
      buildInputs = [ sqlite ]
        ++ lib.optional withLvm lvm2
        ++ lib.optional withBtrfs btrfs-progs
        ++ lib.optional withSystemd systemd
        ++ lib.optional withSeccomp libseccomp;

      extraPath = lib.optionals stdenv.isLinux (lib.makeBinPath [ iproute2 iptables e2fsprogs xz xfsprogs procps util-linux git ]);

      extraUserPath = lib.optionals (stdenv.isLinux && !clientOnly) (lib.makeBinPath [ rootlesskit slirp4netns fuse-overlayfs ]);

      patches = [
        # This patch incorporates code from a PR fixing using buildkit with the ZFS graph driver.
        # It could be removed when a version incorporating this patch is released.
        (fetchpatch {
          name = "buildkit-zfs.patch";
          url = "https://github.com/moby/moby/pull/43136.patch";
          sha256 = "1WZfpVnnqFwLMYqaHLploOodls0gHF8OCp7MrM26iX8=";
        })
      ];

      postPatch = ''
        patchShebangs hack/make.sh hack/make/
      '';

      buildPhase = ''
        export GOCACHE="$TMPDIR/go-cache"
        # build engine
        cd ./go/src/${goPackagePath}
        export AUTO_GOPATH=1
        export DOCKER_GITCOMMIT="${rev}"
        export VERSION="${version}"
        ./hack/make.sh dynbinary
        cd -
      '';

      installPhase = ''
        cd ./go/src/${goPackagePath}
        install -Dm755 ./bundles/dynbinary-daemon/dockerd $out/libexec/docker/dockerd

        makeWrapper $out/libexec/docker/dockerd $out/bin/dockerd \
          --prefix PATH : "$out/libexec/docker:$extraPath"

        ln -s ${docker-containerd}/bin/containerd $out/libexec/docker/containerd
        ln -s ${docker-containerd}/bin/containerd-shim $out/libexec/docker/containerd-shim
        ln -s ${docker-runc}/bin/runc $out/libexec/docker/runc
        ln -s ${docker-proxy}/bin/docker-proxy $out/libexec/docker/docker-proxy
        ln -s ${docker-tini}/bin/tini-static $out/libexec/docker/docker-init

        # systemd
        install -Dm644 ./contrib/init/systemd/docker.service $out/etc/systemd/system/docker.service
        substituteInPlace $out/etc/systemd/system/docker.service --replace /usr/bin/dockerd $out/bin/dockerd
        install -Dm644 ./contrib/init/systemd/docker.socket $out/etc/systemd/system/docker.socket

        # rootless Docker
        install -Dm755 ./contrib/dockerd-rootless.sh $out/libexec/docker/dockerd-rootless.sh
        makeWrapper $out/libexec/docker/dockerd-rootless.sh $out/bin/dockerd-rootless \
          --prefix PATH : "$out/libexec/docker:$extraPath:$extraUserPath"
      '';

      DOCKER_BUILDTAGS = lib.optional withSystemd "journald"
        ++ lib.optional (!withBtrfs) "exclude_graphdriver_btrfs"
        ++ lib.optional (!withLvm) "exclude_graphdriver_devicemapper"
        ++ lib.optional withSeccomp "seccomp";
    });

    plugins = lib.optional buildxSupport docker-buildx
      ++ lib.optional composeSupport docker-compose;
    pluginsRef = symlinkJoin { name = "docker-plugins"; paths = plugins; };
  in
  buildGoPackage (lib.optionalAttrs (!clientOnly) {
    # allow overrides of docker components
    # TODO: move packages out of the let...in into top-level to allow proper overrides
    inherit docker-runc docker-containerd docker-proxy docker-tini moby;
  } // rec {
    pname = "docker";
    inherit version;

    src = fetchFromGitHub {
      owner = "docker";
      repo = "cli";
      rev = "v${version}";
      sha256 = sha256;
    };

    goPackagePath = "github.com/docker/cli";

    nativeBuildInputs = [
      makeWrapper pkg-config go-md2man go libtool installShellFiles
    ];
    buildInputs = lib.optional (!clientOnly) sqlite
      ++ lib.optional withLvm lvm2
      ++ lib.optional withBtrfs btrfs-progs
      ++ lib.optional withSystemd systemd
      ++ lib.optional withSeccomp libseccomp
      ++ plugins;

    postPatch = ''
      patchShebangs man scripts/build/
      substituteInPlace ./scripts/build/.variables --replace "set -eu" ""
    '' + lib.optionalString (plugins != []) ''
      substituteInPlace ./cli-plugins/manager/manager_unix.go --replace /usr/libexec/docker/cli-plugins \
          "${pluginsRef}/libexec/docker/cli-plugins"
    '';

    # Keep eyes on BUILDTIME format - https://github.com/docker/cli/blob/${version}/scripts/build/.variables
    buildPhase = ''
      export GOCACHE="$TMPDIR/go-cache"

      cd ./go/src/${goPackagePath}
      # Mimic AUTO_GOPATH
      mkdir -p .gopath/src/github.com/docker/
      ln -sf $PWD .gopath/src/github.com/docker/cli
      export GOPATH="$PWD/.gopath:$GOPATH"
      export GITCOMMIT="${rev}"
      export VERSION="${version}"
      export BUILDTIME="1970-01-01T00:00:00Z"
      source ./scripts/build/.variables
      export CGO_ENABLED=1
      go build -tags pkcs11 --ldflags "$GO_LDFLAGS" github.com/docker/cli/cmd/docker
      cd -
    '';

    outputs = ["out" "man"];

    installPhase = ''
      cd ./go/src/${goPackagePath}
      install -Dm755 ./docker $out/libexec/docker/docker

      makeWrapper $out/libexec/docker/docker $out/bin/docker \
        --prefix PATH : "$out/libexec/docker:$extraPath"
    '' + lib.optionalString (!clientOnly) ''
      # symlink docker daemon to docker cli derivation
      ln -s ${moby}/bin/dockerd $out/bin/dockerd
      ln -s ${moby}/bin/dockerd-rootless $out/bin/dockerd-rootless

      # systemd
      mkdir -p $out/etc/systemd/system
      ln -s ${moby}/etc/systemd/system/docker.service $out/etc/systemd/system/docker.service
      ln -s ${moby}/etc/systemd/system/docker.socket $out/etc/systemd/system/docker.socket
    '' + ''
      # completion (cli)
      installShellCompletion --bash ./contrib/completion/bash/docker
      installShellCompletion --fish ./contrib/completion/fish/docker.fish
      installShellCompletion --zsh  ./contrib/completion/zsh/_docker
    '' + lib.optionalString (stdenv.hostPlatform == stdenv.buildPlatform) ''
      # Generate man pages from cobra commands
      echo "Generate man pages from cobra"
      mkdir -p ./man/man1
      go build -o ./gen-manpages github.com/docker/cli/man
      ./gen-manpages --root . --target ./man/man1
    '' + ''
      # Generate legacy pages from markdown
      echo "Generate legacy manpages"
      ./man/md2man-all.sh -q

      installManPage man/*/*.[1-9]
    '';

    passthru = {
      # Exposed for tarsum build on non-linux systems (build-support/docker/default.nix)
      inherit moby-src;
      tests = lib.optionals (!clientOnly) { inherit (nixosTests) docker; };
    };

    meta = with lib; {
      homepage = "https://www.docker.com/";
      description = "An open source project to pack, ship and run any application as a lightweight container";
      license = licenses.asl20;
      maintainers = with maintainers; [ offline tailhook vdemeester periklis mikroskeem maxeaubrey ];
    };
  });

  # Get revisions from
  # https://github.com/moby/moby/tree/${version}/hack/dockerfile/install/*
  docker_20_10 = callPackage dockerGen rec {
    version = "20.10.21";
    rev = "v${version}";
    sha256 = "sha256-hPQ1t7L2fqoFWoinqIrDwFQ1bo9TzMb4l3HmAotIUS8=";
    moby-src = fetchFromGitHub {
      owner = "moby";
      repo = "moby";
      rev = "v${version}";
      sha256 = "sha256-BcYDh/UEmmURt7hWLWdPTKVu/Nzoeq/shE+HnUoh8b4=";
    };
    runcRev = "v1.1.4";
    runcSha256 = "sha256-ougJHW1Z+qZ324P8WpZqawY1QofKnn8WezP7orzRTdA=";
    containerdRev = "v1.6.9";
    containerdSha256 = "sha256-KvQdYQLzgt/MKPsA/mO5un6nE3/xcvVYwIveNn/uDnU=";
    tiniRev = "v0.19.0";
    tiniSha256 = "sha256-ZDKu/8yE5G0RYFJdhgmCdN3obJNyRWv6K/Gd17zc1sI=";
  };
}
