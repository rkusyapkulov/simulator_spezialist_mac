// simulator_rk86.h
#ifndef SIMULATOR_rk86_H
#define SIMULATOR_rk86_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define SCREEN_WIDTH  384
#define SCREEN_HEIGHT 256

void spezialist_init(const char *monitor_path, const char* loader_path);
void spezialist_run_frame(void);
void spezialist_reset(void);
const uint32_t* spezialist_get_pixel_buffer(void);
void spezialist_press_key(int row, int bit, bool isPressed);
void spezialist_get_audio_samples(int16_t *buffer, int sample_count);
bool spezialist_load_file(const char *filepath, char *out_msg, size_t msg_max_len);

#endif // SIMULATOR_rk86_H

