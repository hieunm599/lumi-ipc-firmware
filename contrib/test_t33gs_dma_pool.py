#!/usr/bin/env python3
"""Exercise SDK channel allocation with a pressure-sensitive DMA pool model."""
import argparse
from pathlib import Path
import subprocess
import tempfile


HEADER = r'''
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#define PAGE_SIZE 4096
#define ENOMEM 12
#define GFP_KERNEL 1
#define GFP_NOWAIT 2
typedef unsigned long dma_addr_t;
struct hdma_desc { unsigned int words[8]; };
struct device { int unused; };
struct chan_device { struct device device; };
struct dma_device { struct device *dev; };
struct dma_chan { struct chan_device *dev; struct dma_device *device; };
struct dma_pool { int backed, used; unsigned char bytes[PAGE_SIZE]; };
struct ingenic_dma_chan {
 struct dma_chan chan;
 struct dma_pool *hdesc_pool;
 int hdesc_max, hdesc_num;
};
#define to_ingenic_dma_chan(c) ((struct ingenic_dma_chan *)(c))
static int create_fail, backing_fail, pressure, destroyed, backing_allocations;
static const char *last_error;
static const char *dev_name(struct device *d) { (void)d; return "test"; }
#define dev_err(d,msg) do { (void)(d); last_error=(msg); } while(0)
static struct dma_pool *dma_pool_create(const char *name, struct device *dev,
 size_t size, size_t align, size_t boundary) {
 (void)name; (void)dev; assert(size==sizeof(struct hdma_desc));
 assert(!align && boundary==PAGE_SIZE);
 return create_fail ? NULL : calloc(1,sizeof(struct dma_pool));
}
static void *dma_pool_alloc(struct dma_pool *p,int flags,dma_addr_t *dma) {
 assert(p && (flags==GFP_KERNEL || flags==GFP_NOWAIT));
 if(!p->backed) {
  if(backing_fail || (pressure && flags==GFP_NOWAIT)) return NULL;
  p->backed=1; backing_allocations++;
 }
 if(p->used==(int)(PAGE_SIZE/sizeof(struct hdma_desc))) return NULL;
 *dma=(dma_addr_t)(p->bytes+p->used*sizeof(struct hdma_desc));
 return p->bytes+(p->used++)*sizeof(struct hdma_desc);
}
static void dma_pool_free(struct dma_pool *p,void *desc,dma_addr_t dma) {
 assert(p && p->used>0 && desc==(void *)dma); p->used--;
 /* Matches mm/dmapool.c: returning a block does not free its page. */
}
static void dma_pool_destroy(struct dma_pool *p) {
 assert(p && !p->used); destroyed++; free(p);
}
#define CHECK(c,msg) do { if(!(c)) { fprintf(stderr,"FAIL: %s\n",msg); exit(1); } } while(0)
'''

MAIN = r'''
static void reset(void) {
 create_fail=backing_fail=pressure=destroyed=backing_allocations=0;
 last_error=NULL;
}
int main(void) {
 struct device dev={0}; struct chan_device cd={{0}};
 struct dma_device dd={&dev};
 struct ingenic_dma_chan c={.chan={&cd,&dd}};
 void *desc[PAGE_SIZE/sizeof(struct hdma_desc)];
 dma_addr_t dma[PAGE_SIZE/sizeof(struct hdma_desc)]; int i;
 reset(); pressure=1;
 CHECK(ingenic_dma_alloc_chan_resources(&c.chan)==0,"channel preallocation must reclaim under pressure");
 CHECK(c.hdesc_pool && c.hdesc_pool->backed && !c.hdesc_pool->used,
       "channel must retain its descriptor page before NOWAIT prep");
 CHECK(c.hdesc_max==PAGE_SIZE/sizeof(struct hdma_desc) && !c.hdesc_num,
       "preserve the existing one-page descriptor limit");
 for(i=0;i<c.hdesc_max;i++) {
  desc[i]=dma_pool_alloc(c.hdesc_pool,GFP_NOWAIT,&dma[i]);
  CHECK(desc[i]!=NULL,"bounded NOWAIT prep must not allocate a backing page under pressure");
 }
 CHECK(backing_allocations==1,"descriptor pool must have exactly one backing page");
 for(i=c.hdesc_max-1;i>=0;i--) dma_pool_free(c.hdesc_pool,desc[i],dma[i]);
 dma_pool_destroy(c.hdesc_pool); c.hdesc_pool=NULL; c.hdesc_max=0;
 CHECK(destroyed==1,"normal channel release must destroy its pool once");
 reset(); create_fail=1;
 CHECK(ingenic_dma_alloc_chan_resources(&c.chan)==-ENOMEM && !c.hdesc_pool,
       "pool creation failure must reject the channel");
 CHECK(!destroyed && last_error,"creation failure must log without destroying a missing pool");
 reset(); backing_fail=1;
 CHECK(ingenic_dma_alloc_chan_resources(&c.chan)==-ENOMEM,
       "backing allocation failure must reject the channel");
 CHECK(!c.hdesc_pool && !c.hdesc_max && !c.hdesc_num && destroyed==1 && last_error,
       "backing allocation failure must log and clean the unpublished pool");
 puts("PASS: DMA pool preallocation, bounded pressure path and failure cleanup");
 return 0;
}
'''


def extract(source):
    start = source.index("static int ingenic_dma_alloc_chan_resources(")
    end = source.index("static void ingenic_dma_free_chan_resources(", start)
    return source[start:end]


def run(function, directory, name):
    src = directory / (name + ".c")
    exe = directory / name
    src.write_text(HEADER + function + MAIN)
    subprocess.run(["cc", "-std=gnu99", "-Wall", "-Wextra", "-Werror",
                    str(src), "-o", str(exe)], check=True)
    return subprocess.run([str(exe)], capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--negative-proof", action="store_true")
    args = parser.parse_args()
    function = extract(args.source.read_text())
    with tempfile.TemporaryDirectory(prefix="t33-dma-pool-") as temporary:
        directory = Path(temporary)
        result = run(function, directory, "allowed")
        if result.returncode:
            raise SystemExit(result.stderr)
        print(result.stdout.strip())
        if args.negative_proof:
            # Reproduce the original empty pool without touching product source.
            start = function.index("\twarm_desc = dma_pool_alloc(")
            end = function.index("\tdmac->hdesc_max =", start)
            mutation = function[:start] + function[end:]
            mutation = mutation.replace("\tdma_addr_t warm_dma;\n", "")
            mutation = mutation.replace("\tvoid *warm_desc;\n", "")
            result = run(mutation, directory, "unpopulated")
            expected = "channel must retain its descriptor page before NOWAIT prep"
            if result.returncode == 0 or expected not in result.stderr:
                raise SystemExit("FAIL: unpopulated-pool mutation escaped the pressure regression")
            print("PASS: original empty-pool behavior rejected for pressure regression")


if __name__ == "__main__":
    main()
