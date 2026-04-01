//! Async runtime management for FFI entry points.
//!
//! The C-ABI functions called from Dart are synchronous. Internally,
//! each function spawns a task on a shared Tokio runtime and blocks
//! until the result is available.

use std::sync::OnceLock;
use tokio::runtime::Runtime;

/// Global Tokio runtime shared by all sessions.
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Returns a reference to the global runtime, initializing on first call.
pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("bluessh-worker")
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

/// Blocks the current thread on an async future.
pub fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    runtime().block_on(fut)
}
