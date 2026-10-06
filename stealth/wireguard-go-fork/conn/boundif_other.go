//go:build !android

// Fix for Proton's fork: boundif_android.go is android-only (filename suffix),
// but bind_std.go calls PeekLookAtSocketFd4/6 unconditionally.
// This file provides the same implementations for all other platforms.
// The SyscallConn approach works on Linux, Windows, etc.

package conn

func (bind *StdNetBind) PeekLookAtSocketFd4() (fd int, err error) {
	sysconn, err := bind.ipv4.SyscallConn()
	if err != nil {
		return -1, err
	}
	err = sysconn.Control(func(f uintptr) {
		fd = int(f)
	})
	if err != nil {
		return -1, err
	}
	return
}

func (bind *StdNetBind) PeekLookAtSocketFd6() (fd int, err error) {
	sysconn, err := bind.ipv6.SyscallConn()
	if err != nil {
		return -1, err
	}
	err = sysconn.Control(func(f uintptr) {
		fd = int(f)
	})
	if err != nil {
		return -1, err
	}
	return
}
