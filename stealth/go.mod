module github.com/6oodyyyyy/roblox-stealth

go 1.26.1

require golang.zx2c4.com/wireguard v0.0.0-20260323142622-8338bafb983e

require (
	github.com/andybalholm/brotli v1.0.6 // indirect
	github.com/klauspost/compress v1.17.4 // indirect
	github.com/refraction-networking/utls v1.8.2 // indirect
	golang.org/x/crypto v0.36.0 // indirect
	golang.org/x/net v0.38.0 // indirect
	golang.org/x/sys v0.31.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20211104114900-415007cec224 // indirect
)

replace golang.zx2c4.com/wireguard => ./wireguard-go-fork
