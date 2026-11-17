--- Persisted, monotonic event sequence numbers.
---
--- Writing the persist store on every event costs too much, so a block of
--- `stride` numbers is reserved at a time. The invariant: the stored mark is
--- never below a number already handed out, and a reload continues above it.
--- A reload may skip numbers; it never repeats one.
---
--- Why repeating one matters: event ids are built from the sequence
--- (module:instance:boot:sequence), and the platform keeps the FIRST copy of
--- an id and acknowledges a repeat as an accepted duplicate. A repeated number
--- loses the new event without any error anywhere.
---
--- The scheme this replaces reserved only when the count reached a multiple
--- of the stride (seq % stride == 1). A reload resumes one past the mark, which
--- skips that point, so nothing was reserved again until the next multiple; a
--- second reload before then handed the same numbers out again. On the bench
--- every Director reload restarted the Flight Recorder at the same number, and
--- everything it sent after 15 Nov 2026 was answered "duplicate" and dropped.
local M = {}

M.STRIDE = 25

--- Returns a function that hands out the next sequence number.
--- @param store table  anything with get(key, default) and set(key, value)
--- @param key string   the persist key holding the mark
--- @param stride number|nil  numbers reserved per write (default 25)
function M.new(store, key, stride)
  stride = stride or M.STRIDE
  local seq, reserved = nil, nil
  return function()
    if seq == nil then
      local mark = tonumber(store:get(key, 0)) or 0
      -- The old scheme could hand out up to stride-1 numbers past its mark
      -- without moving it, so a reload starts above that. Against a mark this
      -- module wrote, that only skips a few numbers.
      seq = mark > 0 and (mark + stride - 1) or 0
      reserved = seq
    end
    seq = seq + 1
    if seq > reserved then
      reserved = seq + stride
      store:set(key, reserved)
    end
    return seq
  end
end

return M
