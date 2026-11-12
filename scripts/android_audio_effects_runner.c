#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include "client.h"

static struct {
#define API(name) __typeof__(mpv_##name) *name;
    API(create) API(set_option_string) API(request_log_messages)
    API(initialize) API(command_async) API(wait_event)
    API(get_property_string) API(get_property) API(free_node_contents) API(free) API(terminate_destroy)
#undef API
} api;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void quoted(const char *s) {
    putchar('"');
    for (; s && *s; s++) {
        unsigned char c = *s;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 32) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

static int audio_rate(mpv_handle *handle) {
    mpv_node params = {0};
    int rate = 0;
    if (api.get_property(handle, "audio-params", MPV_FORMAT_NODE, &params) < 0) return rate;
    if (params.format == MPV_FORMAT_NODE_MAP) {
        for (int i = 0; i < params.u.list->num; i++) {
            mpv_node *value = &params.u.list->values[i];
            if (!strcmp(params.u.list->keys[i], "samplerate") && value->format == MPV_FORMAT_INT64)
                rate = (int)value->u.int64;
        }
    }
    api.free_node_contents(&params);
    return rate;
}

static mpv_handle *create_handle(char **argv, const char *filter, int append) {
    mpv_handle *handle = api.create();
    if (!handle) return NULL;
    const char *options[][2] = {
        {"config", "no"}, {"load-scripts", "no"}, {"terminal", "no"},
        {"vo", "null"}, {"ao", "pcm"}, {"ao-pcm-waveheader", "no"},
        {"ao-pcm-file", argv[3]}, {"audio-format", "float"},
        {"audio-samplerate", argv[5]},
        {"audio-channels", atoi(argv[6]) == 5 ? "5.0" : atoi(argv[6]) == 3 ? "3.0" : "stereo"},
        {"demuxer-lavf-format", argv[10]}, {"af", filter},
        {"ao-pcm-append", append ? "yes" : "no"}, {"start", argv[12]}
    };
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
        if (!options[i][1][0]) continue;
        int code = api.set_option_string(handle, options[i][0], options[i][1]);
        printf("[\"api\",\"%s\",%d]\n", options[i][0], code);
        if (code < 0) return NULL;
    }
    if (api.request_log_messages(handle, "warn") < 0) return NULL;
    int code = api.initialize(handle);
    printf("[\"api\",\"initialize\",%d]\n", code);
    return code < 0 ? NULL : handle;
}

int main(int argc, char **argv) {
    if (argc != 14) return 2;
    double started_at = now();
    setvbuf(stdout, NULL, _IOLBF, 0);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
#define LOAD(name) api.name = dlsym(library, "mpv_" #name); if (!api.name) return 2
    LOAD(create); LOAD(set_option_string); LOAD(request_log_messages);
    LOAD(initialize); LOAD(command_async); LOAD(wait_event);
    LOAD(get_property_string); LOAD(get_property); LOAD(free_node_contents); LOAD(free); LOAD(terminate_destroy);
#undef LOAD
    FILE *file = fopen(argv[4], "rb");
    if (!file || fseek(file, 0, SEEK_END)) return 2;
    long size = ftell(file);
    if (size < 0 || fseek(file, 0, SEEK_SET)) return 2;
    char *graph = malloc((size_t)size + 1);
    if (!graph || fread(graph, 1, size, file) != (size_t)size) return 2;
    graph[size] = 0;
    fclose(file);
    char *filter = malloc((size_t)size + 100);
    if (!filter) return 2;
    if (!strncmp(graph, "AF:", 3))
        snprintf(filter, (size_t)size + 100, "%s", graph + 3);
    else
        snprintf(filter, (size_t)size + 100, "format=channels=stereo,@effects:lavfi=o=[threads=1]:graph=%%%ld%%%s", size, graph);
    struct action { double when; size_t argc; char **argv; int retried, reconfig_rate; } *actions;
    size_t action_count;
    int observe_reconfigs = 0;
    FILE *action_file = fopen(argv[11], "rb");
    if (!action_file || fscanf(action_file, "%zu", &action_count) != 1) return 2;
    actions = calloc(action_count, sizeof(*actions));
    if (action_count && !actions) return 2;
    for (size_t i = 0; i < action_count; i++) {
        if (fscanf(action_file, "%lf %zu", &actions[i].when, &actions[i].argc) != 2 ||
            fgetc(action_file) != '\n' || !actions[i].argc) return 2;
        actions[i].argv = calloc(actions[i].argc + 1, sizeof(char *));
        if (!actions[i].argv) return 2;
        for (size_t j = 0; j < actions[i].argc; j++) {
            size_t length;
            if (fscanf(action_file, "%zu", &length) != 1 || fgetc(action_file) != '\n') return 2;
            char *argument = calloc(length + 1, 1);
            if (!argument || fread(argument, 1, length, action_file) != length ||
                fgetc(action_file) != '\n') return 2;
            actions[i].argv[j] = argument;
        }
        if (!strcmp(actions[i].argv[0], "on-audio-reconfig")) {
            if (actions[i].argc < 3 || atoi(actions[i].argv[1]) <= 0) return 2;
            actions[i].reconfig_rate = atoi(actions[i].argv[1]);
            // This prefix is runner metadata, never a libmpv command.
            actions[i].argv += 2;
            actions[i].argc -= 2;
            observe_reconfigs = 1;
        }
    }
    fclose(action_file);
    mpv_handle *handle = create_handle(argv, filter, action_count > 0);
    if (!handle) return 3;
    unsigned initialized = 1;
    printf("[\"initialized\",%u]\n", initialized);
    FILE *updates = fopen(argv[8], "r");
    if (!updates) return 2;
    struct update { double when, value; int retried; } *values = NULL;
    size_t count = 0;
    double when, value;
    while (fscanf(updates, "%lf %lf", &when, &value) == 2) {
        struct update *next = realloc(values, (count + 1) * sizeof(*values));
        if (!next) return 2;
        values = next;
        values[count++] = (struct update){when, value, 0};
    }
    fclose(updates);
    const char *active_target = argv[9];
    const char *load[] = {"loadfile", argv[2], "replace", NULL};
    if (api.command_async(handle, 1, load) < 0) return 3;
    double deadline = now() + atof(argv[7]), loaded_at = -1, ended_at = -1, output_at = -1;
    unsigned sent = 0, sent_actions = 0;
    int loading = 1;
    while (now() < deadline) {
        mpv_event *event = api.wait_event(handle, 0.05);
        int reconfigured_rate = -1;
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            printf("[\"log\","); quoted(message->prefix); putchar(',');
            quoted(message->level); putchar(','); quoted(message->text); puts("]");
        } else if (event->event_id) {
            printf("[\"event\",%d,%d,%llu]\n", event->event_id, event->error,
                   (unsigned long long)event->reply_userdata);
            if (observe_reconfigs && event->event_id == MPV_EVENT_AUDIO_RECONFIG) {
                reconfigured_rate = audio_rate(handle);
                struct stat output;
                long long bytes = !stat(argv[3], &output) ? (long long)output.st_size : 0;
                printf("[\"audio_reconfig\",%d,%lld]\n", reconfigured_rate, bytes);
            }
            if (event->event_id == MPV_EVENT_COMMAND_REPLY && event->error == -12 &&
                event->reply_userdata >= 100 && event->reply_userdata < 100 + sent) {
                unsigned index = event->reply_userdata - 100;
                const char *bare = strchr(argv[9], '@');
                if (bare && !values[index].retried) {
                    values[index].retried = 1;
                    active_target = bare + 1;
                    char amount[80];
                    snprintf(amount, sizeof(amount), "%.17g", values[index].value);
                    const char *args[] = {"af-command", "effects", "volume", amount, active_target, NULL};
                    int code = api.command_async(handle, event->reply_userdata, args);
                    printf("[\"retry\",%u,", index); quoted(active_target);
                    printf(",%d]\n", code);
                }
            }
            if (event->event_id == MPV_EVENT_COMMAND_REPLY && event->reply_userdata >= 1000 &&
                event->reply_userdata < 1000 + sent_actions) {
                printf("[\"action_reply\",%llu,%d,", (unsigned long long)event->reply_userdata - 1000, event->error);
                char *pause = api.get_property_string(handle, "pause");
                quoted(pause); puts("]"); api.free(pause);
                unsigned index = event->reply_userdata - 1000;
                struct action *action = &actions[index];
                if (event->error == -12 && !action->retried && action->argc >= 5 &&
                    !strcmp(action->argv[0], "af-command")) {
                    char *bare = strchr(action->argv[4], '@');
                    if (bare) {
                        action->retried = 1;
                        action->argv[4] = bare + 1;
                        int code = api.command_async(handle, event->reply_userdata, (const char **)action->argv);
                        printf("[\"action_retry\",%u,", index); quoted(bare + 1);
                        printf(",%d]\n", code);
                    }
                }
            }
            if (event->event_id == MPV_EVENT_FILE_LOADED) {
                if (loaded_at < 0) loaded_at = now();
                loading = 0;
                ended_at = -1;
            }
            if (event->event_id == MPV_EVENT_END_FILE) {
                mpv_event_end_file *end = event->data;
                printf("[\"end\",%d,%d]\n", end->reason, end->error);
                ended_at = now();
            }
        }
        // Consume event/data before an action can destroy its owning handle.
        if (loaded_at >= 0 && sent < count && now() - loaded_at >= values[sent].when) {
            char amount[80];
            value = values[sent].value;
            snprintf(amount, sizeof(amount), "%.17g", value);
            const char *args[] = {"af-command", "effects", "volume", amount, active_target, NULL};
            int code = api.command_async(handle, 100 + sent++, args);
            printf("[\"update\",%.17g,%d]\n", value, code);
        }
        if (atoi(argv[13]) && output_at < 0) {
            struct stat output;
            if (!stat(argv[3], &output) && output.st_size > 0) {
                output_at = now();
                printf("[\"action_anchor\",%lld]\n", (long long)output.st_size);
            }
        }
        double action_anchor = atoi(argv[13]) ? output_at : loaded_at;
        if (action_anchor >= 0 && sent_actions < action_count &&
            (actions[sent_actions].reconfig_rate ?
             reconfigured_rate == actions[sent_actions].reconfig_rate :
             now() - action_anchor >= actions[sent_actions].when)) {
            struct action *action = &actions[sent_actions];
            int code;
            if (!strcmp(action->argv[0], "reinit")) {
                if (action->argc != 2) return 2;
                api.terminate_destroy(handle);
                handle = create_handle(argv, filter, 1);
                if (!handle) return 3;
                printf("[\"initialized\",%u]\n", ++initialized);
                const char *next[] = {"loadfile", action->argv[1], "replace", NULL};
                code = api.command_async(handle, 1, next);
                loading = 1;
                ended_at = -1;
                printf("[\"action\",%u,%d]\n", sent_actions, code);
                printf("[\"action_reply\",%u,%d,\"no\"]\n", sent_actions, code);
            } else {
                code = api.command_async(handle, 1000 + sent_actions, (const char **)action->argv);
                if (!strcmp(action->argv[0], "loadfile")) { loading = 1; ended_at = -1; }
                printf("[\"action\",%u,%d]\n", sent_actions, code);
            }
            sent_actions++;
        }
        if (ended_at >= 0 && !loading && sent_actions == action_count && now() - ended_at > .2) break;
    }
    const char *versions[] = {"mpv-version", "ffmpeg-version"};
    for (unsigned i = 0; i < 2; i++) {
        char *version = api.get_property_string(handle, versions[i]);
        printf("[\"version\",\"%s\",", versions[i]); quoted(version); puts("]");
        api.free(version);
    }
    int completed = ended_at >= 0 && !loading && sent_actions == action_count;
    printf("[\"timeout\",%s]\n", completed ? "false" : "true");
    if (!completed) return 4;
    api.terminate_destroy(handle);
    puts("[\"ao_closed\",true]");
    struct timespec cpu;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu);
    printf("[\"usage\",%.9f,%.9f]\n", cpu.tv_sec + cpu.tv_nsec / 1e9, now() - started_at);
    return 0;
}
