/* Hampanel Windows driver companion.
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Original implementation. Exposes a narrowly scoped control device; the
 * management API deliberately stays in the user-mode service.
 */
#ifndef HAMPANEL_IOCTL_H
#define HAMPANEL_IOCTL_H

#include <devioctl.h>

#define HAMPANEL_DEVICE_TYPE 0x8A31
#define HAMPANEL_PROTOCOL_VERSION 1

#define IOCTL_HAMPANEL_PING \
    CTL_CODE(HAMPANEL_DEVICE_TYPE, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_HAMPANEL_GET_VERSION \
    CTL_CODE(HAMPANEL_DEVICE_TYPE, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _HAMPANEL_VERSION_INFO {
    ULONG protocol_version;
    ULONG driver_version;
    ULONG reserved;
} HAMPANEL_VERSION_INFO, *PHAMPANEL_VERSION_INFO;

#endif
