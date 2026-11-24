// Native fcntl(2) bridge for the AKE socket (see MainActivity.kt).
//
// android.system.Os.fcntlInt only exists on API 30 and later, so the
// Kotlin side must not call it on older devices. This library exposes
// the one fcntl form the app needs (F_GETFL / F_SETFL with an int
// argument) on every API level, with the exact semantics of
// Os.fcntlInt: the return value is the fcntl(2) result, and failure
// is reported as -errno so the Kotlin wrapper can raise
// android.system.ErrnoException just like Os does.

#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <sys/socket.h>

// Extracts the raw descriptor from a java.io.FileDescriptor. The
// "descriptor" field is the one libcore itself maintains and it has
// been stable across Android versions.
static int descriptor_of(JNIEnv *env, jobject file_descriptor) {
    jclass cls = (*env)->GetObjectClass(env, file_descriptor);
    if (cls == NULL) {
        return -1;
    }
    jfieldID field = (*env)->GetFieldID(env, cls, "descriptor", "I");
    if (field == NULL) {
        return -1;
    }
    return (*env)->GetIntField(env, file_descriptor, field);
}

JNIEXPORT jint JNICALL
Java_com_markun_tmhb_FcntlCompat_nativeFcntlInt(JNIEnv *env, jobject thiz,
                                                jobject file_descriptor,
                                                jint cmd, jint arg) {
    (void)thiz;
    int fd = descriptor_of(env, file_descriptor);
    if (fd < 0) {
        return -EBADF;
    }
    int result = fcntl(fd, cmd, arg);
    if (result < 0) {
        return -errno;
    }
    return result;
}

JNIEXPORT jint JNICALL
Java_com_markun_tmhb_FcntlCompat_nativeSetsockoptInt(JNIEnv *env, jobject thiz,
                                                     jobject file_descriptor,
                                                     jint level, jint option,
                                                     jint value) {
    (void)thiz;
    int fd = descriptor_of(env, file_descriptor);
    if (fd < 0) {
        return -EBADF;
    }
    int opt = (int)value;
    int result = setsockopt(fd, level, option, &opt, (socklen_t)sizeof(opt));
    if (result < 0) {
        return -errno;
    }
    return 0;
}
