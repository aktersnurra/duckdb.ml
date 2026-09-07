#ifndef STAGE2_NATIVE_BORROW_H
#define STAGE2_NATIVE_BORROW_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct stage2_owner stage2_owner;
/* Status: 0 ready/chunk, 1 exhausted, 2 native failure, 3 schema mismatch. */
stage2_owner *stage2_create(void);
bool stage2_set_sql(stage2_owner *, const char *, size_t);
void stage2_prepare(stage2_owner *);
int stage2_next(stage2_owner *);
int stage2_status(const stage2_owner *);
const char *stage2_message(const stage2_owner *);
size_t stage2_length(const stage2_owner *);
bool stage2_valid(const stage2_owner *, size_t);
int64_t stage2_value(const stage2_owner *, size_t);
/* Test evidence: decimal trace 1=chunk, 2=result, 3=connection, 4=database,
   5=SQL. Reset for each close; zero means the repeated close was a no-op. */
unsigned stage2_close_trace(const stage2_owner *);
void stage2_close(stage2_owner *);
void stage2_delete(stage2_owner *);
int stage2_live_resources(void);
#endif
