#!/usr/bin/env python3
"""Execute extracted allocator code with controlled lists; not board proof."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


HEADER = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#define MAX_ORDER 11
#define MIGRATE_PCPTYPES 3
#define MIGRATE_HIGHATOMIC 3
#define MIGRATE_CMA 4
#define CONFIG_CMA 1
#define ALLOC_HIGH 0x20
#define ALLOC_HARDER 0x10
#define ALLOC_CMA 0x80
#define NR_FREE_CMA_PAGES 0
#define pageblock_nr_pages 1024UL
#define likely(x) (x)
#define min(a,b) ((a)<(b)?(a):(b))
#define pr_warn_once(...) ((void)0)
struct page;
struct list_head { struct page *page; struct list_head *next; };
struct free_area { unsigned long nr_free; struct list_head free_list[5]; };
struct zone {
 unsigned long nr_reserved_highatomic, cma;
 unsigned long lowmem_reserve[1];
 struct free_area free_area[MAX_ORDER];
};
struct page { struct list_head lru; int type, movable_pages; };
struct zonelist { struct zone *zone; };
struct zoneref { int unused; };
struct alloc_context { struct zonelist *zonelist; int high_zoneidx, migratetype; void *nodemask; };
static int held, moves, reduce_on_lock;
#define for_each_zone_zonelist_nodemask(zone,z,list,idx,mask) \
 for ((z)=NULL,(zone)=(list)->zone; (void)(z),(zone); (zone)=NULL)
#define spin_lock_irqsave(lock,flags) do { \
 (flags)=0; assert(!held); held=1; \
 if (reduce_on_lock) { zone->nr_reserved_highatomic-=1024; reduce_on_lock=0; } \
} while(0)
#define spin_unlock_irqrestore(lock,flags) do { (void)(flags); assert(held); held=0; } while(0)
#define list_entry(ptr,type,member) ((ptr)->page)
static bool list_empty(struct list_head *p) { return !p->next; }
static int get_pageblock_migratetype(struct page *p) { return p->type; }
static void set_pageblock_migratetype(struct page *p,int t) { assert(held); p->type=t; }
static int move_freepages_block(struct zone *z,struct page *p,int type) {
 int i; (void)type; assert(held); moves++;
 for(i=0;i<MAX_ORDER;i++)
  if(z->free_area[i].free_list[MIGRATE_HIGHATOMIC].page==p) {
   z->free_area[i].free_list[MIGRATE_HIGHATOMIC].page=NULL;
   z->free_area[i].free_list[MIGRATE_HIGHATOMIC].next=NULL;
  }
 return p->movable_pages;
}
static long zone_page_state(struct zone *z,int item) { (void)item; return z->cma; }
#define CHECK(x,msg) do { if(!(x)) { fprintf(stderr,"FAIL: %s\n",msg); exit(1); } } while(0)
'''

MAIN = r'''
static void seed(struct zone *z,struct page *p,unsigned long reserve,int free_pages) {
 *z=(struct zone){0}; *p=(struct page){0};
 z->nr_reserved_highatomic=reserve; p->type=MIGRATE_HIGHATOMIC;
 p->movable_pages=free_pages; p->lru.page=p;
 z->free_area[0].free_list[MIGRATE_HIGHATOMIC].page=p;
 z->free_area[0].free_list[MIGRATE_HIGHATOMIC].next=&p->lru;
 moves=0; held=0; reduce_on_lock=0;
}
int main(void) {
 struct zone z; struct page p,p2; struct zonelist zl={&z};
 struct alloc_context ac={.zonelist=&zl};
 unsigned long free_kib[]={19148,19948},cma_kib[]={14308,14760};
 int i;
 seed(&z,&p,1024,64);
 CHECK(!unreserve_highatomic_pageblock(&ac,false) && moves==0 && z.nr_reserved_highatomic==1024,
       "ordinary reclaim must preserve final reserve");
 CHECK(before_oom(&ac) && z.nr_reserved_highatomic==0 && moves==1 && !held,
       "before OOM must release final usable reserve and retry");
 CHECK(!before_oom(&ac),"exhausted reserve must not claim progress");
 seed(&z,&p,2048,64); reduce_on_lock=1;
 CHECK(!unreserve_highatomic_pageblock(&ac,false) && moves==0,
       "ordinary reclaim must recheck reservation under lock");
 seed(&z,&p,2048,64);
 CHECK(unreserve_highatomic_pageblock(&ac,false) && z.nr_reserved_highatomic==1024,
       "ordinary reclaim may release surplus reserve");
 seed(&z,&p,1024,0);
 CHECK(!before_oom(&ac) && !held,"zero moved pages must not fake progress");
 seed(&z,&p,2048,0); p2=(struct page){.type=MIGRATE_HIGHATOMIC,.movable_pages=16};
 p2.lru.page=&p2; z.free_area[1].free_list[MIGRATE_HIGHATOMIC].page=&p2;
 z.free_area[1].free_list[MIGRATE_HIGHATOMIC].next=&p2.lru;
 CHECK(before_oom(&ac) && moves==2,"continue after zero-progress candidate");
 seed(&z,&p,0,16);
 CHECK(before_oom(&ac) && z.nr_reserved_highatomic==0,"stale list must not underflow accounting");
 for(i=0;i<2;i++) {
  seed(&z,&p,1024,64); z.cma=cma_kib[i]/4;
  CHECK(!__zone_watermark_ok(&z,0,273,0,0,free_kib[i]/4),"original OOM snapshot should reject");
  CHECK(before_oom(&ac),"snapshot reserve must be recoverable");
  CHECK(__zone_watermark_ok(&z,0,273,0,0,free_kib[i]/4),"released reserve must admit snapshot");
 }
 puts("PASS: ordinary/forced reclaim, lock recheck, real progress, exhaustion, accounting and both OOM snapshots");
 return 0;
}
'''


def extract(source):
    if 'static bool unreserve_highatomic_pageblock(' not in source:
        raise ValueError('Missing force-unreserve fix: apply T33gs patch 0003 first')
    start = source.index('static bool unreserve_highatomic_pageblock(')
    end = source.index('\n/* Remove an element', start)
    unreserve = source[start:end]
    start = source.index('static bool __zone_watermark_ok(')
    end = source.index('\nbool zone_watermark_ok(', start)
    watermark = source[start:end]
    # Execute the actual final-reclaim decision, including its true/false mode.
    marker = '/* Exhaust usable highatomic reserves before killing a process. */'
    start = source.index(marker)
    end = source.index('/* Reclaim has failed us, start killing things */', start)
    decision = source[start:end]
    if not re.fullmatch(r'/\*.*?\*/\s*if \(unreserve_highatomic_pageblock\(ac, (true|false)\)\)\s*goto retry;\s*', decision, re.S):
        raise ValueError('Unsupported pre-OOM decision; inspect the allocator change')
    return (HEADER + unreserve + watermark
            + '\nstatic bool before_oom(const struct alloc_context *ac) {\n'
            + decision + '\nreturn false;\nretry: return true;\n}\n' + MAIN)


def run(source, cc):
    with tempfile.TemporaryDirectory(prefix='t33-highatomic-') as tmp:
        root = Path(tmp)
        (root / 'test.c').write_text(extract(source))
        subprocess.run([cc, '-std=gnu99', '-Wall', '-Wextra', '-Werror',
                        '-Wno-sign-compare', str(root / 'test.c'), '-o', str(root / 'test')], check=True)
        return subprocess.run([str(root / 'test')], capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--cc', default='cc')
    parser.add_argument('--negative-proof', action='store_true')
    args = parser.parse_args()
    source = args.source.read_text()
    try:
        result = run(source, args.cc)
        if result.returncode:
            parser.exit(1, result.stderr)
        print(result.stdout, end='')
        if args.negative_proof:
            cases = [
                (source.replace('unreserve_highatomic_pageblock(ac, true)',
                                'unreserve_highatomic_pageblock(ac, false)'),
                 'before OOM must release final usable reserve and retry'),
                (source.replace('if (ret) {', 'if (ret >= 0) {', 1),
                 'zero moved pages must not fake progress'),
            ]
            for mutation, diagnostic in cases:
                result = run(mutation, args.cc)
                if not result.returncode or diagnostic not in result.stderr:
                    parser.exit(1, 'FAIL: negative proof did not detect ' + diagnostic + '\n')
                print('PASS: negative proof rejected ' + diagnostic)
    except (ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, 'FAIL: T33gs highatomic allocator validation: ' + str(exc) + '\n')


if __name__ == '__main__':
    main()
