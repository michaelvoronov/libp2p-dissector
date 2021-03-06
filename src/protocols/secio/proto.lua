-- prevent wireshark loading this file as a plugin
if not _G['libp2p_dissector'] then return end

local protoc = require ("protoc")

assert(protoc:load [[
    message Propose {
        optional bytes rand = 1;
        optional bytes pubkey = 2;
        optional string exchanges = 3;
        optional string ciphers = 4;
        optional string hashes = 5;
    }

    message Exchange {
        optional bytes epubkey = 1;
        optional bytes signature = 2;
    } ]]
)
