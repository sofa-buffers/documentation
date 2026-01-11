<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers

**Structured Objects For Anyone** \
*... so optimized, feels amazing.*

## Documentation

SofaBuffers is a binary format for serializing and deserializing complex messages consisting of multiple fields, arrays, and nested structures.

## Encodings

Used encodings in SofaBuffers:

### Varint Encoding

Integer values are transmitted as **varint** in SofaBuffers, regardless of the bit width of the data type.
**Varint (variable-length integer)** encodes an integer so that small values require fewer bytes. Each byte uses the most significant bit as a continuation bit: if this bit is set, more bytes follow; otherwise, the value ends.

### Zig-Zag Encoding

For **signed integers**, **Zig-Zag encoding** is also used. This maps negative numbers to positive values, allowing varint to work efficiently for small absolute values.

## Format Specification

Specification of the SofaBuffer binary format:

![SofaBuffers format](assets/format.drawio.svg)

The percentages for the individual field types correspond to the average usage in other message formats such as JSON, protocol buffers, and many more.

This data was used to keep the overhead for frequently used types as low as possible.

### ID and Field Type

* Each field is identified by an **ID**. This must be unique for each sequence.
* IDs are in the range `0 .. INT32_MAX`.
* The type of the field is encoded in the lowest 3 bits of the ID:

| Bits  | Type                          |
|-------|-------------------------------|
| 0b000 | unsigned integer              |
| 0b001 | signed integer                |
| 0b010 | fixlen value                  |
| 0b011 | array of unsigned integers    |
| 0b100 | array of signed integers      |
| 0b101 | array of fixlen values        |
| 0b110 | sequence start                |
| 0b111 | sequence end                  |

* The combination of ID + type is serialized using **varint encoding**.

### Unsigned Integer

* The ID is followed by at least one byte of **varint-encoded unsigned integers**.
* The parser requires a temporary 64-bit buffer for sequential decoding of the stream.
* If the receiver is interested in the field, the value is then written to the destination buffer as an **unsigned** value.

### Signed Integer

* The ID is followed by at least one byte of the **varint-encoded unsigned integer**.
* The parser requires a temporary 64-bit buffer to sequentially decode the stream.
* After decoding, the value is **zig-zag decoded** into a signed integer.
* If the receiver is interested in the field, the value is then written to the destination buffer as a **signed** value.

### Fixlen Length and Type

* Each fixlen field begins with **fixlen length information** for the value.
* Lengths are in the range `0 .. INT32_MAX`.
* The type of the fixlen field is encoded in the lowest three bits of the length:

| Bits  | Type                                    |
|-------|-----------------------------------------|
| 0b000 | IEEE754 32-bit float (LE)               |
| 0b001 | IEEE754 64-bit double (LE)              |
| 0b010 | UTF-8 string (without null termination) |
| 0b011 | BLOB (arbitrary binary data)            |
| 0b100 | reserved                                |
| 0b101 | reserved                                |
| 0b110 | reserved                                |
| 0b111 | reserved                                |

* Length + type are serialized using **varint encoding**.
* If the receiver ignores the field, the parser can skip the bytes based on the length.

### Fixlen Value

* The **Fixlen length information** is followed by the payload data corresponding to the specified length.
* For IEEE754 types, the endianness must be converted correctly to **Little Endian** depending on the system.

### Array of ...

* The ID is followed by the **number of array elements**.
* Array sizes are in the range `1 .. INT32_MAX`.
* This information is used by the parser to check whether all values fit into the target buffer.
* If the receiver is not interested in the field, the parser can skip the elements based on the number.

#### Array of Unsigned Integer

* The number of elements is followed by **varint-encoded unsigned integers**.
* The number of bytes can vary per element due to varint.
* The parser requires a temporary 64-bit buffer to sequentially decode the stream.
* If the receiver is interested in the field, each value is written to the corresponding offset after decoding.

#### Array of Signed Integer

* The number of elements is followed by **varint-encoded unsigned integers**.
* The number of bytes can vary per element due to varint.
* The parser requires a temporary 64-bit buffer to sequentially decode the stream.
* After decoding, each value is **zig-zag decoded** into a signed integer.
* If the receiver is interested in the field, each value is written to the corresponding offset after decoding.

#### Array of Fixlen Values

* The number of elements is followed by the **Fixlen length information**, which applies to all elements.
* Arrays of dynamic types (UTF-8, BLOB) are not allowed; instead a sequence should be used for dynamic arrays.
* The following payload data is treated as consecutive fixlen values.

### Sequence Start

* A sequence can be viewed as an embedded message or structure.
* A new ID scope is opened for each new sequence; conflicts with IDs of the parent sequence are not possible.
* Sequences can be used for:
  * Nested structures
  * Arrays with a dynamic number of elements
  * Arrays with dynamic content (e.g., array of strings)

### Sequence Stop

* This special type has no ID (value = 0).
* It signals the end of a sequence, so that the following fields belong to the parent sequence again.
* With this stop field, a sequence can be serialized without knowing its size in advance.
* When deserializing, the parser must traverse the sequence, including nested sequences if necessary, even if there is no interest in the data.

---

## Implementation requirements

Every implementation **must be streaming-capable** in order to enable the **incremental** (chunked) transmission and reception of large messages, thereby keeping memory requirements as low as possible.

### Serialization

During serialization, it must be possible to process large messages without the output buffer having to be the same size as the message.
Specifically, this means that during serialization, it must be possible to use a **smaller output buffer** than the actual message.

### Deserialization

During deserialization, it must be ensured that the parser can be fed with **arbitrarily small data chunks**.
This is the only way to guarantee that true streaming capability is also available on the input side.
