# mqtt-zig

An MQTT broker written in the [Zig](https://ziglang.org/) programming language, focusing on performance, safety, and zero runtime memory allocations. It utilizes the [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle) client's I/O abstraction layer for efficient, cross-platform event handling (epoll, kqueue, io_uring, etc.).

## ✨ Features

* **MQTT Protocol:** Aims for MQTT v3.1.1 compliance.
* **Written in Zig:** Leverages Zig's features for safety, performance, and compile-time evaluation.
* **Zero Runtime Allocation:** Designed to operate without allocating memory on the heap during runtime, leading to predictable performance and suitability for resource-constrained environments. All necessary memory is allocated at startup or managed via arenas reset per-connection/event.
* **High Performance:** Built for speed and low latency, benefiting from Zig's direct memory control and TigerBeetle's efficient I/O.
* **Cross-Platform I/O:** Uses TigerBeetle's `IO` interface, providing a unified abstraction over modern asynchronous I/O mechanisms like `epoll` (Linux), `kqueue` (macOS/BSD).
* **Minimal Dependencies:** Aims for a small footprint and few external runtime dependencies.

## 🤔 Motivation

The goal of `mqtt-zig` is to:

1.  Explore the capabilities of Zig for building high-performance network servers.
2.  Provide a robust and extremely performant MQTT broker alternative.
3.  Achieve predictable latency and resource usage by strictly avoiding runtime memory allocations.
4.  Leverage the excellent, battle-tested I/O layer provided by TigerBeetle.

## ❗ Status

**[Experimental]**

This project is currently under active development. It is **not yet recommended for production use**. Expect breaking changes and incomplete features.

## ⚙️ Prerequisites

* **Zig Compiler:** Version `0.14.0`. You can find installation instructions [here](https://ziglang.org/learn/getting-started/).
* **Git:** For cloning the repository.

## 🛠️ Building

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Alfagov/mqtt-zig.git
    cd mqtt-zig
    ```
    
2. **Build the project:**
    * For a development build:
        ```bash
        zig build
        ```
    * For an optimized release build:
        ```bash
        zig build -Doptimize=ReleaseFast
        ```

    The executable will be located in `./zig-out/bin/mqtt-zig`.

## 🚀 Running

## 🔧 Configuration

## 🙏 Acknowledgements

* The [Zig community](https://ziglang.org/) for creating an amazing language.
* The [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle) project for its high-performance database and the excellent standalone I/O library.
* Contributors to the MQTT specification.