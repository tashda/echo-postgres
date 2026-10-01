// libpq's C API for this module: echo-libraries' universal build on macOS, the system's on Linux.
#if canImport(CLibpq)
@_exported import CLibpq
#else
@_exported import CLibpqSystem
#endif

#if canImport(Darwin)
@_exported import Darwin
#elseif canImport(Glibc)
@_exported import Glibc
#endif
