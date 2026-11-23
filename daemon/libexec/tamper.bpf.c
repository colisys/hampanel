/* CO-RE field relocations; no dependency on build-host kernel headers. */
#define SEC(name) __attribute__((section(name), used))
#define CORE __attribute__((preserve_access_index))
typedef unsigned long long u64;
struct super_block { unsigned int s_dev; } CORE;
struct inode { unsigned long i_ino; struct super_block *i_sb; } CORE;
struct dentry { struct inode *d_inode; } CORE;
struct file { struct inode *f_inode; unsigned int f_mode; } CORE;
struct path { struct dentry *dentry; } CORE;
struct identity { u64 dev, ino; };
struct { int (*type)[1]; int (*max_entries)[64]; struct identity *key; unsigned char *value; } guards SEC(".maps");
static void *(*lookup)(void *, const void *) = (void *)1;
static __inline __attribute__((always_inline)) int deny(struct inode *i) {
    if (!i) return 0;
    struct identity k = { i->i_sb->s_dev, i->i_ino };
    return lookup(&guards, &k) ? -1 : 0;
}
/* The final context slot is the previous LSM BPF program's result. */
SEC("lsm/file_permission") int hp_write(u64 *c) {
    return c[2] ? (int)c[2] : (c[1] & (2|8)) ? deny(((struct file *)c[0])->f_inode) : 0;
}
SEC("lsm/file_open") int hp_open(u64 *c) {
    struct file *f = (void *)c[0];
    return c[1] ? (int)c[1] : (f->f_mode & 2) ? deny(f->f_inode) : 0;
}
SEC("lsm/path_truncate") int hp_trunc(u64 *c) {
    return c[1] ? (int)c[1] : deny(((struct path *)c[0])->dentry->d_inode);
}
SEC("lsm/file_truncate") int hp_ftrunc(u64 *c) {
    return c[1] ? (int)c[1] : deny(((struct file *)c[0])->f_inode);
}
SEC("lsm/inode_unlink") int hp_unlink(u64 *c) {
    return c[2] ? (int)c[2] : deny(((struct dentry *)c[1])->d_inode);
}
SEC("lsm/inode_rename") int hp_rename(u64 *c) {
    if (c[4]) return (int)c[4];
    return deny(((struct dentry *)c[1])->d_inode) ?: deny(((struct dentry *)c[3])->d_inode);
}
struct vm_area_struct { struct file *vm_file; unsigned long vm_flags; } CORE;
SEC("lsm/mmap_file") int hp_mmap(u64 *c) {
    if (c[4]) return (int)c[4];
    struct file *f = (void *)c[0];
    return f && (c[2] & 2) && (c[3] & 1) ? deny(f->f_inode) : 0;
}
SEC("lsm/file_mprotect") int hp_mprotect(u64 *c) {
    if (c[3]) return (int)c[3];
    struct vm_area_struct *v = (void *)c[0];
    if (!(c[2] & 2) || !(v->vm_flags & 8)) return 0;
    struct file *f = v->vm_file;
    return f ? deny(f->f_inode) : 0;
}
char hp_license[] SEC("license") = "GPL";
