/*
 * Minimal getopt_long for Windows
 *
 * Provides just enough of the POSIX getopt_long interface for screen2cam.
 * Header-only, ~80 lines. Only included on _WIN32 — POSIX systems use <getopt.h>.
 *
 * MinGW often ships <getopt.h> but bundling avoids CI surprises with
 * different toolchain versions.
 */

#ifndef GETOPT_WIN_H
#define GETOPT_WIN_H

#ifdef _WIN32

#include <string.h>
#include <stdio.h>

static char *optarg = NULL;
static int   optind = 1;
static int   opterr = 1;
static int   optopt = 0;

#define no_argument       0
#define required_argument 1
#define optional_argument 2

struct option {
    const char *name;
    int         has_arg;
    int        *flag;
    int         val;
};

static inline int getopt_long(int argc, char *const argv[],
                               const char *optstring,
                               const struct option *longopts,
                               int *longindex)
{
    (void)longindex;

    if (optind >= argc || !argv[optind])
        return -1;

    char *arg = argv[optind];

    /* Long option: --name or --name=value */
    if (arg[0] == '-' && arg[1] == '-' && arg[2] != '\0') {
        const char *name = arg + 2;
        const char *eq = strchr(name, '=');
        size_t nlen = eq ? (size_t)(eq - name) : strlen(name);

        for (int i = 0; longopts && longopts[i].name; i++) {
            if (strncmp(longopts[i].name, name, nlen) == 0 &&
                strlen(longopts[i].name) == nlen) {
                optind++;
                if (longopts[i].has_arg == required_argument) {
                    if (eq) {
                        optarg = (char *)(eq + 1);
                    } else if (optind < argc) {
                        optarg = argv[optind++];
                    } else {
                        if (opterr)
                            fprintf(stderr, "%s: option '--%s' requires an argument\n",
                                    argv[0], longopts[i].name);
                        return '?';
                    }
                } else if (eq && longopts[i].has_arg == no_argument) {
                    if (opterr)
                        fprintf(stderr, "%s: option '--%s' doesn't allow an argument\n",
                                argv[0], longopts[i].name);
                    return '?';
                }
                return longopts[i].val;
            }
        }
        if (opterr)
            fprintf(stderr, "%s: unrecognized option '%s'\n", argv[0], arg);
        optind++;
        return '?';
    }

    /* Short option: -X or -Xvalue */
    if (arg[0] == '-' && arg[1] != '\0') {
        char c = arg[1];
        const char *p = strchr(optstring, c);
        if (!p) {
            optopt = c;
            optind++;
            if (opterr)
                fprintf(stderr, "%s: invalid option -- '%c'\n", argv[0], c);
            return '?';
        }
        optind++;
        if (p[1] == ':') {
            /* Argument required */
            if (arg[2] != '\0') {
                optarg = arg + 2;
            } else if (optind < argc) {
                optarg = argv[optind++];
            } else {
                optopt = c;
                if (opterr)
                    fprintf(stderr, "%s: option requires an argument -- '%c'\n", argv[0], c);
                return '?';
            }
        }
        return c;
    }

    return -1;
}

#endif /* _WIN32 */
#endif /* GETOPT_WIN_H */
