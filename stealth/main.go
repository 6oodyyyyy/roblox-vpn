// RobloxVPN Stealth client — WireGuard-over-TLS (Proton Stealth protocol)
// for bypassing DPI that fingerprints plain WireGuard.
//
// Uses ProtonVPN's open-source wireguard-go fork (GPL-3.0) which implements
// the Stealth transport: TCP+TLS (uTLS Chrome fingerprint) with TunSafe
// framing and decoy SNI.
//
// Usage: stealth-wg.exe <config.conf> [interface-name]
// Status is printed as JSON lines to stdout for the Python frontend to parse.

package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	server_name_utils "golang.zx2c4.com/wireguard/conn/server_name_utils"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

const (
	defaultMTU       = 1320 // lower than 1420 to account for TLS+TCP overhead
	stealthPort      = 443
	statusInterval   = 2 * time.Second
)

// WgConfig holds the parsed .conf values we need.
type WgConfig struct {
	PrivateKey          string
	Address             string
	PeerPublicKey       string
	EndpointIP          string
	AllowedIPs          string
	PersistentKeepalive int
}

// StatusLine is the JSON status printed to stdout.
type StatusLine struct {
	Type          string `json:"type"` // "status" | "error" | "ready"
	HandshakeOK   bool   `json:"handshake_ok,omitempty"`
	LastHandshake int64  `json:"last_handshake_unix,omitempty"`
	RxBytes       int64  `json:"rx_bytes,omitempty"`
	TxBytes       int64  `json:"tx_bytes,omitempty"`
	Message       string `json:"message,omitempty"`
}

func emit(s StatusLine) {
	b, _ := json.Marshal(s)
	fmt.Println(string(b))
}

func parseConf(path string) (*WgConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	cfg := &WgConfig{PersistentKeepalive: 25}
	section := ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(line[1 : len(line)-1])
			continue
		}
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(kv[0]))
		val := strings.TrimSpace(kv[1])
		switch section {
		case "interface":
			switch key {
			case "privatekey":
				cfg.PrivateKey = val
			case "address":
				// take first (IPv4) address if multiple
				cfg.Address = strings.TrimSpace(strings.Split(val, ",")[0])
			}
		case "peer":
			switch key {
			case "publickey":
				cfg.PeerPublicKey = val
			case "endpoint":
				// strip port, we force 443 for Stealth
				host := val
				if h, _, err := net.SplitHostPort(val); err == nil {
					host = h
				} else if i := strings.LastIndex(val, ":"); i > 0 && !strings.Contains(val[i:], "]") {
					host = val[:i]
				}
				host = strings.Trim(host, "[]")
				cfg.EndpointIP = host
			case "allowedips":
				cfg.AllowedIPs = val
			case "persistentkeepalive":
				var ka int
				fmt.Sscanf(val, "%d", &ka)
				if ka > 0 {
					cfg.PersistentKeepalive = ka
				}
			}
		}
	}
	if cfg.PrivateKey == "" || cfg.PeerPublicKey == "" || cfg.EndpointIP == "" {
		return nil, fmt.Errorf("config missing PrivateKey/PublicKey/Endpoint")
	}
	if cfg.AllowedIPs == "" {
		cfg.AllowedIPs = "128.116.0.0/17"
	}
	return cfg, sc.Err()
}

func b64ToHex(s string) (string, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: stealth-wg.exe <config.conf> [ifname]")
		os.Exit(2)
	}
	confPath := os.Args[1]
	ifName := "RobloxVPN-Stealth"
	if len(os.Args) > 2 {
		ifName = os.Args[2]
	}

	cfg, err := parseConf(confPath)
	if err != nil {
		emit(StatusLine{Type: "error", Message: "parse config: " + err.Error()})
		os.Exit(1)
	}

	privHex, err := b64ToHex(cfg.PrivateKey)
	if err != nil {
		emit(StatusLine{Type: "error", Message: "bad PrivateKey: " + err.Error()})
		os.Exit(1)
	}
	pubHex, err := b64ToHex(cfg.PeerPublicKey)
	if err != nil {
		emit(StatusLine{Type: "error", Message: "bad PublicKey: " + err.Error()})
		os.Exit(1)
	}

	// 1. TUN device
	tunDev, err := tun.CreateTUN(ifName, defaultMTU)
	if err != nil {
		emit(StatusLine{Type: "error", Message: "create TUN: " + err.Error()})
		os.Exit(1)
	}

	// 2. Stealth bind (TLS over TCP/443, Chrome-fingerprint uTLS, decoy SNI)
	errChan := make(chan error, 1)
	connLogger := &conn.Logger{
		Verbosef: func(format string, args ...any) {},
		Errorf:   func(format string, args ...any) { fmt.Fprintf(os.Stderr, "[stealth] "+format+"\n", args...) },
	}
	protectSocket := func(fd int) int { return 0 } // no-op: split-tunnel avoids routing loop
	bind := conn.CreateStdNetBind("tls", server_name_utils.ServerNameTop, connLogger, errChan, protectSocket)

	// 3. WireGuard device
	devLogger := device.NewLogger(device.LogLevelError, "wg: ")
	wgDev := device.NewDevice(tunDev, bind, devLogger, nil, "")
	defer wgDev.Close()

	// 4. Configure via IPC
	var ipc strings.Builder
	fmt.Fprintf(&ipc, "private_key=%s\n", privHex)
	fmt.Fprintf(&ipc, "listen_port=0\n")
	fmt.Fprintf(&ipc, "replace_peers=true\n")
	fmt.Fprintf(&ipc, "public_key=%s\n", pubHex)
	fmt.Fprintf(&ipc, "endpoint=%s:%d\n", cfg.EndpointIP, stealthPort)
	for _, aip := range strings.Split(cfg.AllowedIPs, ",") {
		aip = strings.TrimSpace(aip)
		if aip != "" {
			fmt.Fprintf(&ipc, "allowed_ip=%s\n", aip)
		}
	}
	fmt.Fprintf(&ipc, "persistent_keepalive_interval=%d\n", cfg.PersistentKeepalive)
	if err := wgDev.IpcSet(ipc.String()); err != nil {
		emit(StatusLine{Type: "error", Message: "configure device: " + err.Error()})
		os.Exit(1)
	}

	// 5. Up
	if err := wgDev.Up(); err != nil {
		emit(StatusLine{Type: "error", Message: "device up: " + err.Error()})
		os.Exit(1)
	}

	emit(StatusLine{Type: "ready", Message: "stealth tunnel up, waiting for handshake"})

	// 6. Status loop
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	ticker := time.NewTicker(statusInterval)
	defer ticker.Stop()
	for {
		select {
		case <-sigCh:
			wgDev.Close()
			return
		case err := <-errChan:
			emit(StatusLine{Type: "error", Message: "bind error: " + err.Error()})
		case <-ticker.C:
			rx, tx, hs := peerStats(wgDev)
			emit(StatusLine{
				Type:          "status",
				HandshakeOK:   !hs.IsZero(),
				LastHandshake: hs.Unix(),
				RxBytes:       rx,
				TxBytes:       tx,
			})
		}
	}
}

func peerStats(wgDev *device.Device) (rx, tx int64, hs time.Time) {
	var sb strings.Builder
	if err := wgDev.IpcGetOperation(&sb); err != nil {
		return 0, 0, time.Time{}
	}
	for _, line := range strings.Split(sb.String(), "\n") {
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "rx_bytes":
			fmt.Sscanf(kv[1], "%d", &rx)
		case "tx_bytes":
			fmt.Sscanf(kv[1], "%d", &tx)
		case "last_handshake_time_sec":
			var sec int64
			fmt.Sscanf(kv[1], "%d", &sec)
			if sec > 0 {
				hs = time.Unix(sec, 0)
			}
		}
	}
	return rx, tx, hs
}
