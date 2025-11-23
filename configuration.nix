{ config, pkgs, lib, webrtcPkg, pyEnv, webrtcEnv, robotConsoleStatic, robotApiPkg, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "692338a991740a8f1f3201a7";
  homeDir   = "/home/${user}";

  py  = pkgs.python3;   # pinned to 3.12 by flake overlay

  rosPkgs = pkgs.rosPackages.humble;
  ros2pkg = rosPkgs.ros2pkg;
  ros2cli = rosPkgs.ros2cli;
  ros2launch = rosPkgs.ros2launch;
  launch = rosPkgs.launch;
  launch-ros = rosPkgs.launch-ros;
  rclpy = rosPkgs.rclpy;
  ament-index-python = rosPkgs.ament-index-python;
  rosidl-parser = rosPkgs.rosidl-parser;
  rosidl-runtime-py = rosPkgs.rosidl-runtime-py;
  composition-interfaces = rosPkgs.composition-interfaces;
  osrf-pycommon = rosPkgs.osrf-pycommon;
  rpyutils = rosPkgs.rpyutils;
  rcl-interfaces = rosPkgs.rcl-interfaces;
  builtin-interfaces = rosPkgs.builtin-interfaces;
  rmwImplementation = rosPkgs."rmw-implementation";
  rmwCycloneDDS = rosPkgs."rmw-cyclonedds-cpp";
  rmwDdsCommon = rosPkgs."rmw-dds-common";
  rosidlTypesupportCpp = rosPkgs."rosidl-typesupport-cpp";
  rosidlTypesupportC = rosPkgs."rosidl-typesupport-c";
  rosidlTypesupportIntrospectionCpp = rosPkgs."rosidl-typesupport-introspection-cpp";
  rosidlTypesupportIntrospectionC = rosPkgs."rosidl-typesupport-introspection-c";
  rosidlGeneratorPy = rosPkgs."rosidl-generator-py";
  yaml = pkgs.python3Packages."pyyaml";
  empy = pkgs.python3Packages."empy";
  catkin-pkg = pkgs.python3Packages."catkin-pkg";
  rosgraphMsgs = rosPkgs."rosgraph-msgs";
  stdMsgs = rosPkgs."std-msgs";

  rosRuntimePackages = [
    ros2pkg
    ros2cli
    ros2launch
    launch
    launch-ros
    rclpy
    ament-index-python
    rosidl-parser
    rosidl-runtime-py
    composition-interfaces
    osrf-pycommon
    rpyutils
    builtin-interfaces
    rcl-interfaces
    rmwImplementation
    rmwCycloneDDS
    rmwDdsCommon
    rosidlTypesupportCpp
    rosidlTypesupportC
    rosidlTypesupportIntrospectionCpp
    rosidlTypesupportIntrospectionC
    rosidlGeneratorPy
    rosgraphMsgs
    stdMsgs
    yaml
  ];

  pythonRoots = rosRuntimePackages ++ [ pyEnv webrtcEnv webrtcPkg ];
  pythonPath = lib.makeSearchPath "lib/python${py.pythonVersion}/site-packages" pythonRoots;

  amentRoots = rosRuntimePackages ++ [ webrtcPkg ];
  amentPrefixPath = lib.concatStringsSep ":" (map (pkg: "${pkg}") amentRoots);

  webrtcRuntimeInputs = rosRuntimePackages ++ [ pyEnv webrtcEnv webrtcPkg ];
  runtimePrefixes = lib.concatStringsSep " " (map (pkg: "${pkg}") webrtcRuntimeInputs);
  libraryPath = lib.makeLibraryPath webrtcRuntimeInputs;

  webrtcLauncher = pkgs.writeShellApplication {
    name = "webrtc-launch";
    runtimeInputs = webrtcRuntimeInputs;
    text = ''
      set -eo pipefail

      # Guard PATH/PYTHONPATH before enabling nounset; systemd often runs with them unset.
      PATH="''${PATH-}"
      PYTHONPATH="''${PYTHONPATH-}"
      AMENT_PREFIX_PATH="''${AMENT_PREFIX_PATH-}"
      LD_LIBRARY_PATH="''${LD_LIBRARY_PATH-}"
      if [ -z "''${RMW_IMPLEMENTATION-}" ]; then
        RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
      fi
      export RMW_IMPLEMENTATION

      set -u
      shopt -s nullglob

      PYTHONPATH_BASE="${pythonPath}"
      if [ -n "$PYTHONPATH_BASE" ]; then
        PYTHONPATH="$PYTHONPATH_BASE''${PYTHONPATH:+:}''${PYTHONPATH}"
      fi

      AMENT_PREFIX_BASE="${amentPrefixPath}"
      if [ -n "$AMENT_PREFIX_BASE" ]; then
        AMENT_PREFIX_PATH="$AMENT_PREFIX_BASE''${AMENT_PREFIX_PATH:+:}''${AMENT_PREFIX_PATH}"
      fi

      LIBRARY_PATH_BASE="${libraryPath}"
      if [ -n "$LIBRARY_PATH_BASE" ]; then
        LD_LIBRARY_PATH="$LIBRARY_PATH_BASE''${LD_LIBRARY_PATH:+:}''${LD_LIBRARY_PATH}"
      fi

      export PYTHONPATH
      export AMENT_PREFIX_PATH
      export LD_LIBRARY_PATH

      # Local setup scripts expect AMENT_TRACE_SETUP_FILES to be unset when absent.
      set +u
      for prefix in ${runtimePrefixes}; do
        for script in "$prefix"/setup.bash "$prefix"/local_setup.bash \
                      "$prefix"/install/setup.bash "$prefix"/install/local_setup.bash \
                      "$prefix"/share/*/local_setup.bash "$prefix"/share/*/setup.bash; do
          if [ -f "$script" ]; then
            echo "[INFO] Sourcing $script" >&2
            # shellcheck disable=SC1090
            . "$script"
          fi
        done
      done
      set -u

      exec ros2 launch webrtc webrtc.launch.py
    '';
  };

  wifiConfPath = "/var/lib/polyflow/wifi.conf";

  # Switch between hotspot (AP) and client (STA) depending on presence of saved Wi-Fi credentials.
  # Credentials file: /var/lib/polyflow/wifi.conf with lines:
  #   WIFI_SSID="MyNetwork"
  #   WIFI_PSK="supersecret"
  wifiModeSwitch = pkgs.writeShellApplication {
    name = "polyflow-wifi-mode";
    runtimeInputs = [ pkgs.networkmanager pkgs.gawk pkgs.coreutils ];
    text = ''
      set -euo pipefail

      HOSTNAME="${hostname}"
      WIFI_CONF="${wifiConfPath}"
     
      # wait up to ~10s for NM + wifi device
      for _ in $(seq 1 20); do
        if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ":wifi"; then
          break
        fi
        sleep 0.5
      done

      WIFI_IF="$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1;exit}')"
      if [ -z "$WIFI_IF" ]; then
        echo "[wifi-mode] No Wi-Fi interface found" >&2
        exit 0
      fi

      ensure_ap() {
        local ap_ssid="polyflow-robot-setup"
        local ap_pass="${password}"

        if ! nmcli -t -f NAME connection show | grep -Fx "robot-ap" >/dev/null; then
          # Add AP profile with shared-mode up front to avoid race on first activation
          nmcli connection add type wifi ifname "$WIFI_IF" mode ap con-name robot-ap ssid "$ap_ssid" \
            ipv4.method shared ipv6.method ignore

          nmcli connection modify robot-ap \
            802-11-wireless.band bg \
            802-11-wireless.channel 1 \
            802-11-wireless-security.key-mgmt wpa-psk \
            802-11-wireless-security.psk "$ap_pass"
        fi

        nmcli connection modify robot-ap connection.autoconnect yes || true

        # Remove any stale dnsmasq pid that can block shared-mode start (iface-safe)
        rm -f "/run/nm-dnsmasq-''${WIFI_IF}.pid" 2>/dev/null || true

        # Force a clean up/down to dodge first-boot AP races
        nmcli connection down robot-ap || true
        nmcli connection up robot-ap || true
      }

      # If no credentials, start AP
      if [ ! -f "$WIFI_CONF" ]; then
        echo "[wifi-mode] wifi.conf missing; enabling AP mode" >&2
        ensure_ap
        exit 0
      fi

      # Read credentials
      WIFI_SSID=""
      WIFI_PSK=""
      # shellcheck disable=SC1090
      source "$WIFI_CONF" || true
      if [ -z "''${WIFI_SSID:-}" ]; then
        echo "[wifi-mode] WIFI_SSID empty; enabling AP mode" >&2
        ensure_ap
        exit 0
      fi

      # Find the first robot-wifi UUID (if any)
      ROBOT_UUID="$(nmcli -t -f UUID,NAME connection show \
        | awk -F: '$2=="robot-wifi"{print $1; exit}')"

      if [ -z "$ROBOT_UUID" ]; then
        nmcli connection add type wifi ifname "$WIFI_IF" con-name robot-wifi ssid "$WIFI_SSID"
        # Capture UUID for the newly created connection so we never rely on NAME
        ROBOT_UUID="$(nmcli -t -f UUID,NAME connection show \
          | awk -F: '$2=="robot-wifi"{print $1; exit}')"
      else
        nmcli connection modify "$ROBOT_UUID" 802-11-wireless.ssid "$WIFI_SSID"
      fi

      if [ -n "''${WIFI_PSK:-}" ]; then
        nmcli connection modify "$ROBOT_UUID" \
          802-11-wireless-security.key-mgmt wpa-psk \
          802-11-wireless-security.psk "$WIFI_PSK" \
          802-11-wireless-security.psk-flags 0
      else
        nmcli connection modify "$ROBOT_UUID" 802-11-wireless-security.key-mgmt none
        # (Per your request, not applying my earlier “clear stale PSK” suggestion.)
      fi

      nmcli connection modify "$ROBOT_UUID" \
        ipv4.method auto \
        ipv6.method auto \
        connection.autoconnect yes \
        connection.permissions ""

      # Optional stability tweak (NOT forcing, just leaving note):
      # If STA bring-up is slow/flaky on some networks, consider:
      # nmcli connection modify "$ROBOT_UUID" ipv6.method disabled

      # Keep AP disabled whenever creds are present to avoid concurrent AP+STA.
      nmcli connection modify robot-ap connection.autoconnect no || true

      echo "[wifi-mode] Bringing up STA connection to SSID=$WIFI_SSID" >&2
      rm -f "/run/nm-dnsmasq-''${WIFI_IF}.pid" 2>/dev/null || true
      nmcli connection down robot-ap || true

      # Re-apply PSK every run to ensure NM has the secret stored.
      if [ -n "''${WIFI_PSK:-}" ]; then
        nmcli connection modify "$ROBOT_UUID" \
          802-11-wireless-security.key-mgmt wpa-psk \
          802-11-wireless-security.psk "$WIFI_PSK"
      fi

      if nmcli connection up "$ROBOT_UUID"; then
        echo "[wifi-mode] STA connected; AP will remain off while creds exist" >&2
      else
        echo "[wifi-mode] STA connection failed; re-enabling AP for setup" >&2
        nmcli connection modify robot-ap connection.autoconnect yes || true
        ensure_ap
        exit 0
      fi
    '';
  };

in
{
  ##############################################################################
  # Hardware / boot
  ##############################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x:
        super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  imports = [
    "${builtins.fetchGit {
      url = "https://github.com/NixOS/nixos-hardware.git";
      rev = "26ed7a0d4b8741fe1ef1ee6fa64453ca056ce113";
    }}/raspberry-pi/4"
  ];

  boot = {
    # Default kernel is fine; swap if you need rpi4-specific later.
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
    # Quiet kernel output on console (keep in journal)
    consoleLogLevel = 3; # errors only
    kernel.sysctl."kernel.printk" = "3 4 1 3";
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  ##############################################################################
  # System basics
  ##############################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    networkmanager.wifi.powersave = false;
    networkmanager.logLevel = "WARN";
    nftables.enable = true;
    firewall = {
      allowedTCPPorts = [ 80 ];
      # Allow DHCP/DNS on the hotspot interface so clients can get leases.
      interfaces."wlan0" = {
        allowedUDPPorts = [ 53 67 68 ];
        allowedTCPPorts = [ 53 ];
      };
    };
  };
  services.openssh.enable = true;
  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.addresses = true;
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/polyflow 0755 root root -"
    # Clean any stale dnsmasq PID file NetworkManager might leave
    "r /run/nm-dnsmasq-wlan0.pid"
  ];
  services.caddy.enable = false;

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = false;
    virtualHosts."default" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
      ];
      locations = {
        # Strip the /api/ prefix when proxying to the FastAPI app
        "/api/".proxyPass = "http://127.0.0.1:8082/";
        "/" = {
          root = "${robotConsoleStatic}/dist";
          tryFiles = "$uri $uri/ /index.html";
          extraConfig = "autoindex off;";
        };
      };
    };
  };
  
  # Build-time NSS in the sandbox lacks a root entry; skip logrotate config check
  # to avoid failing builds in nixos-generate/docker.
  services.logrotate.checkConfig = false;
  services.timesyncd.enable = lib.mkDefault true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  # No extra NSS modules; disable nscd to avoid PID file permission warnings.
  system.nssModules = lib.mkForce [];
  services.nscd.enable = false;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" user ];
    trusted-substituters = [ "https://ros.cachix.org" ];
    trusted-public-keys = [
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };
  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";

  # Optional: keep a copy of this file on the device
  environment.etc."nixos/configuration.nix" = {
    source = ./configuration.nix;
    mode = "0644";
  };
  environment.etc."alloy/config.alloy" = {
    source = ./alloy-config.alloy;
    mode = "0644";
  };

  ##############################################################################
  # Users
  ##############################################################################
  users.mutableUsers = false;
  # Keep an explicit root entry so builds that query user 0 (e.g., logrotate.conf)
  # can resolve it even with immutable users. Set uid/gid explicitly and lock the
  # password so root password auth stays disabled.
  users.groups.root.gid = 0;
  users.users.root = {
    uid = 0;
    group = "root";
    isSystemUser = true;
    hashedPassword = "!";
  };
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  ##############################################################################
  # Packages
  ##############################################################################
  environment.systemPackages =
    (with pkgs; [ git python3 ]) ++
    (with rosPkgs; [ ros2cli ros2launch ros2pkg launch launch-ros ament-index-python ros-base ]) ++
    [ webrtcPkg pyEnv ];

  ##############################################################################
  # Services
  ##############################################################################
  # Boot-time Wi-Fi mode selection: hotspot when no creds, STA when configured.
  systemd.services.polyflow-wifi-mode = {
    description = "Polyflow Wi-Fi mode switch (AP vs STA)";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" "network-online.target" ];
    wants = [ "NetworkManager.service" "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${wifiModeSwitch}/bin/polyflow-wifi-mode";
      RemainAfterExit = true;
      Restart = "no"; # be explicit
    };
  };

  systemd.paths.polyflow-wifi-mode = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = wifiConfPath;
      PathExists = wifiConfPath;
      Unit = "polyflow-wifi-mode.service";
    };
  };

  systemd.services.polyflow-robot-api = {
    description = "Polyflow Robot REST API";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      WIFI_CONF_PATH = wifiConfPath;
      WIFI_SWITCH_CMD = "${wifiModeSwitch}/bin/polyflow-wifi-mode";
      ROBOT_API_TOKEN_PATH = "/var/lib/polyflow/api_token";
      ROBOT_API_ALLOWED_ORIGINS = "http://localhost,http://127.0.0.1,http://localhost:5173,http://127.0.0.1:5173,http://localhost:4173,http://127.0.0.1:4173,http://${hostname}.local";
    };
    serviceConfig = {
      ExecStart = "${robotApiPkg}/bin/robot-api";
      WorkingDirectory = "/var/lib/polyflow";
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };

  systemd.services.grafana-alloy = {
    description = "Grafana Alloy metrics collector";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.grafana-alloy}/bin/alloy run /etc/alloy/config.alloy";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      Environment = "ROBOT_ID=${hostname}";
    };
  };

  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    wantedBy = [ "multi-user.target" ];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    restartIfChanged = true;
    restartTriggers = [ webrtcPkg webrtcEnv webrtcLauncher ];

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = homeDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart          = "always";
      RestartSec       = "3s";
      ExecStart        = "${webrtcLauncher}/bin/webrtc-launch";
    };
  };
}
