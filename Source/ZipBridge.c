#include <zlib.h>
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

int lab_inflate(const uint8_t *input, size_t input_size,
                uint8_t *output, size_t output_size) {
    if (input_size > UINT_MAX || output_size > UINT_MAX) return -1;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_size;
    stream.next_out = output;
    stream.avail_out = (uInt)output_size;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -2;
    int result = inflate(&stream, Z_FINISH);
    int valid = result == Z_STREAM_END && stream.total_out == output_size
                && stream.total_in == input_size;
    inflateEnd(&stream);
    return valid ? 0 : -3;
}

uint32_t lab_crc32(const uint8_t *bytes, size_t count) {
    uLong crc = crc32(0L, Z_NULL, 0);
    while (count) {
        uInt chunk = count > UINT_MAX ? UINT_MAX : (uInt)count;
        crc = crc32(crc, bytes, chunk);
        bytes += chunk;
        count -= chunk;
    }
    return (uint32_t)crc;
}

long lab_inflate_zlib(const uint8_t *input, size_t input_size,
                      uint8_t *output, size_t capacity) {
    uLongf length = capacity;
    int result = uncompress(output, &length, input, input_size);
    return result == Z_OK ? (long)length : -1;
}

long lab_inflate_prefix(const uint8_t *input, size_t input_size,
                        uint8_t *output, size_t capacity) {
    if (input_size > UINT_MAX || capacity > UINT_MAX) return -1;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)input_size;
    stream.next_out = output; stream.avail_out = (uInt)capacity;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -1;
    int result = inflate(&stream, Z_NO_FLUSH);
    long count = (result == Z_OK || result == Z_STREAM_END) ? (long)stream.total_out : -1;
    inflateEnd(&stream);
    return count;
}
