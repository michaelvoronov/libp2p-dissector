-- prevent wireshark loading this file as a plugin
if not _G['secio_dissector'] then return end

local config = require("config")
local utils = require("secio_misc")
local pb = require ("pb")
local SecioState = require ("secio_state")

local listener_hmac_size = utils:hashSize(config.local_hmac_type)
local dialer_hmac_size = utils:hashSize(config.remote_hmac_type)
local listenerMsgDecryptor = utils:makeMsgDecryptor(config.local_cipher_type, config.local_key, config.local_iv)
local dialerMsgDecryptor = utils:makeMsgDecryptor(config.remote_cipher_type, config.remote_key, config.remote_iv)

secio_proto = Proto("secio", "SECIO protocol")

local fields = secio_proto.fields

-- fields related to Propose packets type
fields.propose = ProtoField.bytes ("secio.propose", "Propose", base.NONE, nil, 0, "Propose request")
fields.rand = ProtoField.bytes ("secio.propose.rand", "rand", base.NONE, nil, 0, "Propose random bytes")
fields.pubkey = ProtoField.bytes ("secio.propose.pubkey", "pubkey", base.NONE, nil, 0, "Propose public key")
fields.exchanges = ProtoField.string ("secio.propose.exchanges", "exchanges", base.NONE, nil, 0, "Propose exchanges")
fields.ciphers = ProtoField.string ("secio.propose.ciphers", "ciphers", base.NONE, nil, 0, "Propose ciphers")
fields.hashes = ProtoField.string ("secio.propose.hashes", "hashes", base.NONE, nil, 0, "Propose hashes")

-- fields related to Exchange packets type
fields.exchange = ProtoField.bytes ("secio.exchange", "exchange", base.NONE, nil, 0, "Exchange request")
fields.epubkey = ProtoField.bytes ("secio.exchange.epubkey", "epubkey", base.NONE, nil, 0, "Ephermal public key")
fields.signature = ProtoField.bytes ("secio.exchange.signature", "signature", base.NONE, nil, 0, "Exchange signature")

function secio_proto.dissector (buffer, pinfo, tree)
    -- the message should be at least 4 bytes
    if buffer:len() < 4 then
        return
    end

    local subtree = tree:add(secio_proto, "SECIO protocol")
    pinfo.cols.protocol = secio_proto.name

    -- according to the spec, first 4 bytes always represents packet size
    local packet_len = buffer(0, 4):uint()

    if (SecioState.listenerProposePacketId == -1 or SecioState.dialerProposePacketId == -1) or
            (pinfo.number == SecioState.listenerProposePacketId or pinfo.number == SecioState.dialerProposePacketId) then

        pinfo.cols.info = "SECIO Propose"

        if not pinfo.visited and (SecioState.listenerProposePacketId == -1) then
            SecioState.listenerProposePacketId = pinfo.number
        elseif not pinfo.visited and (SecioState.dialerProposePacketId == -1) then
            SecioState.dialerProposePacketId = pinfo.number
        end

        subtree:add(buffer(0, 4), string.format("Propose message size 0x%x bytes", packet_len))
        local branch = subtree:add("Propose", fields.propose)

        local propose = assert(pb.decode("Propose", buffer:raw(4, -1)))
        local offset = 4

        -- check for fields presence and add them to the tree
        if (propose.rand ~= nil) then
            branch:add(fields.rand, buffer(offset, propose.rand:len() + 3))
            offset = offset + propose.rand:len() + 3
        end

        if (propose.pubkey ~= nil) then
            branch:add(fields.pubkey, buffer(offset, propose.pubkey:len() + 4))
            offset = offset + propose.pubkey:len() + 4
        end

        if (propose.exchanges ~= nil) then
            branch:add(fields.exchanges, buffer(offset, propose.exchanges:len()))
            offset = offset + propose.exchanges:len()
        end

        if (propose.ciphers ~= nil) then
            branch:add(fields.ciphers, buffer(offset + 2, propose.ciphers:len()))
            offset = offset + propose.ciphers:len()
        end

        if (propose.hashes ~= nil) then
            branch:add(fields.hashes, buffer(offset + 4, propose.hashes:len()))
            offset = offset + propose.hashes:len()
        end
    elseif (SecioState.listenerExchangePacketId == -1 or SecioState.dialerExchangePacketId == -1)
            or (pinfo.number == SecioState.listenerExchangePacketId or pinfo.number == SecioState.dialerExchangePacketId) then

        pinfo.cols.info = "SECIO Exchange"

        if not pinfo.visited and (SecioState.listenerExchangePacketId == -1) then
            SecioState.listenerExchangePacketId = pinfo.number
        elseif not pinfo.visited and (SecioState.dialerExchangePacketId == -1) then
            SecioState.dialerExchangePacketId = pinfo.number
        end

        subtree:add(buffer(0, 4), string.format("Exchange message size 0x%x bytes", packet_len))
        local branch = subtree:add("Exchange", fields.exchange)

        local exchange = assert(pb.decode("Exchange", buffer:raw(4, -1)))
        local offset = 4

        -- check for fields presence and add them to the tree
        if (exchange.epubkey ~= nil) then
            branch:add(fields.epubkey, buffer(offset, exchange.epubkey:len() + 2))
            offset = offset + exchange.epubkey:len() + 2
        end

        if (exchange.signature ~= nil) then
            branch:add(fields.signature, buffer(offset, exchange.signature:len() + 2))
            offset = offset + exchange.signature:len() + 2
        end
    else
        pinfo.cols.info = "SECIO Body"
        local plain_text = ""
        local hmac_size = listener_hmac_size

        -- if seen this packet for the first time, we need to decrypt it
        if not pinfo.visited then
            -- [4 bytes len][ cipher_text ][ H(cipher_text) ]
            -- CTR mode AES
            if (config.src_port == pinfo.src_port) then
                plain_text = listenerMsgDecryptor(buffer:raw(4, packet_len - listener_hmac_size))
            else
                plain_text = dialerMsgDecryptor(buffer:raw(4, packet_len - dialer_hmac_size))
                hmac_size = dialer_hmac_size
            end

            SecioState.decryptedPayloads[pinfo.number] = plain_text
        else
            plain_text = SecioState.decryptedPayloads[pinfo.number]
        end

        local offset = 0
        subtree:add(buffer(offset, 4), string.format("MPLEX packet size: 0x%X bytes", packet_len))
        offset = offset + 4

        local mplexTree = subtree:add(buffer(offset, packet_len - hmac_size),
            string.format("cipher text: plain text is (0x%X bytes) %s",
                #plain_text, Struct.tohex(tostring(plain_text)))
        )
        offset = offset + packet_len - hmac_size

        subtree:add(buffer(offset, -1), string.format("HMAC (0x%X bytes)", hmac_size))

        Dissector.get("mplex"):call(buffer(4, packet_len - hmac_size):tvb(), pinfo, mplexTree)
    end
end

return secio_proto
