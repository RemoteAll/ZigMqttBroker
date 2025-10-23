
pub const kernel_backlog = 16;
pub const io_entries = 128;
pub const queue_size = 256;

pub const max_clients = 1024;
pub const max_messages = max_clients;

pub const maximum_message_size = 256 * 1024 + 2;

pub const threads = 1;

pub const maximum_topic_number = 1024;
pub const maximum_topic_subscribers = 100_000;
pub const topic_name_pool_size = threads * 2;
pub const maximum_topic_name_length = 256;