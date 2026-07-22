#!/usr/bin/env python3
"""Extract the strict classic single-disk ZIP STORED subset."""
from __future__ import annotations

import argparse, binascii, ctypes, hashlib, json, os, re, shutil, stat, struct, subprocess, sys, unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import zip_metadata as zm

sys.path.insert(0, str(Path(__file__).parent))
from lib.isolation_profile import PROFILE_INPROCESS_ZIP_STORED

SCHEMA = "zip-stored.v1"
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0); DIRECTORY = getattr(os, "O_DIRECTORY", 0); CLOEXEC = getattr(os, "O_CLOEXEC", 0)


class StoredError(ValueError): pass
class PublishedUnsynced(StoredError): pass


def write_all(fd: int, data: bytes | memoryview) -> None:
    view = memoryview(data)
    while view: view = view[os.write(fd, view):]


def create_file(directory: int, name: str, data: bytes) -> None:
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC, 0o400, dir_fd=directory)
    try: write_all(fd, data); os.fsync(fd)
    finally: os.close(fd)


def stage_input(source: Path, stage_fd: int, limit: int) -> dict[str, Any]:
    src = os.open(source, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW | CLOEXEC); out = -1
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode): raise StoredError("input must be a regular non-symlink file")
        if before.st_size > limit: raise StoredError("input exceeds max-input-bytes")
        resolved = str(Path(f"/proc/self/fd/{src}").resolve()); out = os.open("archive.zip", os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o400, dir_fd=stage_fd)
        digest = hashlib.sha256(); total = 0
        while chunk := os.read(src, min(1048576, limit - total + 1)):
            total += len(chunk)
            if total > limit: raise StoredError("input exceeds max-input-bytes")
            digest.update(chunk); write_all(out, chunk)
        os.fsync(out); after = os.fstat(src)
        fields = lambda x: (x.st_dev,x.st_ino,x.st_mode,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size: raise StoredError("input changed while staging")
        return {"path":resolved,"size":total,"sha256":"sha256:"+digest.hexdigest()}
    finally:
        if out >= 0: os.close(out)
        os.close(src)


def extras(data: bytes) -> None:
    cursor = 0
    while cursor < len(data):
        if cursor + 4 > len(data): raise StoredError("malformed local extra field")
        kind, length = struct.unpack_from("<HH", data, cursor); cursor += 4
        if cursor + length > len(data) or kind == 1: raise StoredError("ZIP64 or malformed local extra field")
        cursor += length


def inspect(fd: int, size: int, args: argparse.Namespace) -> list[dict[str, Any]]:
    parsed, _ = zm.inventory(fd,size,args.max_metadata_bytes,args.max_entries,args.max_metadata_bytes,args.max_report_bytes)
    records=[]; total=0; paths: dict[str,str]={}; declared=set(); ranges=[]; central=parsed["central_directory_offset"]
    for item in parsed["entries"]:
        raw=bytes.fromhex(item["name_raw_hex"])
        if len(raw)>args.max_path_bytes: raise StoredError("entry path exceeds max-path-bytes")
        try: name=raw.decode(item["name_encoding"],errors="strict")
        except UnicodeError as exc: raise StoredError("entry name is not valid in its declared encoding") from exc
        directory=name.endswith("/"); plain=name[:-1] if directory else name; parts=plain.split("/")
        if not plain or name.startswith("/") or "\\" in name or "\0" in name or re.match(r"^[A-Za-z]:",name) or any(x in ("",".","..") or any(ord(c)<32 or ord(c)==127 for c in x) for x in parts) or unicodedata.normalize("NFC",name)!=name: raise StoredError("unsafe entry path")
        if len(parts)>args.max_depth: raise StoredError("entry path exceeds max-depth")
        if plain in declared or any(paths.get("/".join(parts[:i]))=="file" for i in range(1,len(parts))) or (not directory and plain in paths): raise StoredError("duplicate or ancestor path conflict")
        if not directory and any(key.startswith(plain+"/") for key in paths): raise StoredError("file-directory path conflict")
        for i in range(1,len(parts)): paths.setdefault("/".join(parts[:i]),"directory")
        kind="directory" if directory else "file"; paths[plain]=kind; declared.add(plain)
        made_host=item["version_made_by"]>>8; mode=item["external_attributes"]>>16; dos_dir=bool(item["external_attributes"]&0x10)
        if made_host==3 and not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)): raise StoredError("link or special entry attributes are unsupported")
        if made_host!=3 and (dos_dir!=directory or item["external_attributes"]&0x40): raise StoredError("inconsistent or special entry attributes")
        if item["flags"]&(1|8) or item["method"]!=0: raise StoredError("only unencrypted descriptor-free STORED entries are supported")
        if item["compressed_size"]!=item["uncompressed_size"] or (directory and item["uncompressed_size"]): raise StoredError("invalid STORED or directory size")
        if item["uncompressed_size"]>args.max_entry_bytes: raise StoredError("entry exceeds max-entry-bytes")
        total+=item["uncompressed_size"]
        if total>args.max_total_bytes: raise StoredError("extracted bytes exceed max-total-bytes")
        local=parsed["archive_prefix_bytes"]+item["declared_local_header_offset"]; header=zm.pread(fd,30,local); values=struct.unpack("<I5H3I2H",header)
        if values[0]!=0x04034b50: raise StoredError("invalid local-header signature")
        _,needed,flags,method,mtime,mdate,crc,compressed,uncompressed,nlen,xlen=values; fields=zm.pread(fd,nlen+xlen,local+30); local_raw=fields[:nlen]; extras(fields[nlen:])
        expected=(item["version_needed"],item["flags"],item["method"],item["dos_time"],item["dos_date"],int(item["crc32"],16),item["compressed_size"],item["uncompressed_size"],raw)
        if (needed,flags,method,mtime,mdate,crc,compressed,uncompressed,local_raw)!=expected: raise StoredError("central/local header mismatch")
        start=local+30+nlen+xlen; end=start+compressed
        if end>central: raise StoredError("payload range crosses central directory")
        ranges.append((local,end)); records.append({"path":name,"type":kind,"size":uncompressed,"crc32":item["crc32"],"payload_offset":start})
    ordered=sorted(ranges)
    if any(ordered[i][0]<ordered[i-1][1] for i in range(1,len(ordered))): raise StoredError("entry ranges overlap")
    return records


def directory_fd(root: int, parts: list[str]) -> int:
    current=os.dup(root)
    try:
        for part in parts:
            try: os.mkdir(part,0o700,dir_fd=current)
            except FileExistsError: pass
            nxt=os.open(part,os.O_RDONLY|DIRECTORY|NOFOLLOW|CLOEXEC,dir_fd=current); os.close(current); current=nxt
        return current
    except BaseException: os.close(current); raise


def extract(fd: int, stage_fd: int, records: list[dict[str, Any]]) -> None:
    for item in records:
        parts=item["path"].rstrip("/").split("/"); parent=directory_fd(stage_fd,parts if item["type"]=="directory" else parts[:-1])
        try:
            if item["type"]=="directory": continue
            out=os.open(parts[-1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|NOFOLLOW|CLOEXEC,0o400,dir_fd=parent); digest=hashlib.sha256(); crc=0; left=item["size"]; offset=item["payload_offset"]
            try:
                while left:
                    chunk=os.pread(fd,min(left,1048576),offset)
                    if not chunk: raise StoredError("truncated payload")
                    write_all(out,chunk); digest.update(chunk); crc=binascii.crc32(chunk,crc); left-=len(chunk); offset+=len(chunk)
                os.fsync(out)
            finally: os.close(out)
            if f"{crc&0xffffffff:08x}"!=item["crc32"]: raise StoredError("payload CRC32 mismatch")
            item["sha256"]="sha256:"+digest.hexdigest()
        finally: os.close(parent)


def validate(stage: Path, expected: set[str], expected_dirs: set[str]) -> None:
    seen=set(); seen_dirs=set()
    for path in stage.rglob("*"):
        meta=path.lstat(); mode=0o700 if stat.S_ISDIR(meta.st_mode) else 0o400
        if meta.st_uid!=os.getuid() or stat.S_IMODE(meta.st_mode)!=mode: raise StoredError("output ownership or mode violation")
        if stat.S_ISREG(meta.st_mode):
            if meta.st_nlink!=1: raise StoredError("output file has external hardlinks")
            seen.add(str(path.relative_to(stage)))
        elif stat.S_ISDIR(meta.st_mode): seen_dirs.add(str(path.relative_to(stage)))
        else: raise StoredError("output tree contains a link or special file")
    if seen!=expected or seen_dirs!=expected_dirs: raise StoredError("output tree is not closed")
    for path in sorted((x for x in stage.rglob("*") if x.is_dir()),key=lambda x:len(x.parts),reverse=True):
        descriptor=os.open(path,os.O_RDONLY|DIRECTORY|NOFOLLOW); os.fsync(descriptor); os.close(descriptor)
    descriptor=os.open(stage,os.O_RDONLY|DIRECTORY|NOFOLLOW); os.fsync(descriptor); os.close(descriptor)


def publish(parent_fd: int, stage_name: str, destination: str) -> None:
    rename=getattr(ctypes.CDLL(None,use_errno=True),"renameat2",None)
    if rename is None or rename(parent_fd,os.fsencode(stage_name),parent_fd,os.fsencode(destination),1): raise StoredError("atomic no-replace publication failed")
    try: os.fsync(parent_fd)
    except OSError as exc: raise PublishedUnsynced("parent-directory sync failed after publication") from exc


def parser() -> argparse.ArgumentParser:
    p=argparse.ArgumentParser(); p.add_argument("--input",type=Path,required=True); p.add_argument("--output",type=Path,required=True); p.add_argument("--manifest-cli",type=Path,required=True,help=argparse.SUPPRESS); p.add_argument("--metadata-parser",type=Path,required=True,help=argparse.SUPPRESS)
    for name,default in (("max-input-bytes",1073741824),("max-metadata-bytes",16777216),("max-entries",10000),("max-path-bytes",4096),("max-depth",64),("max-entry-bytes",1073741824),("max-total-bytes",1073741824),("max-report-bytes",16777216)): p.add_argument("--"+name,type=int,default=default)
    return p


def main(argv: list[str]|None=None) -> int:
    args=parser().parse_args(argv); stage=None; parent_fd=-1
    try:
        caps={k:v for k,v in vars(args).items() if k.startswith("max_")}
        if min(caps.values())<1 or os.geteuid()==0 or os.getuid()!=os.geteuid() or os.getgid()!=os.getegid(): raise StoredError("caps must be positive and execution unprivileged non-set-id")
        lexical=Path(os.path.abspath(args.output.parent)); probe=Path(lexical.anchor)
        for part in lexical.parts[1:]:
            probe/=part
            if probe.is_symlink(): raise StoredError("output parent links are unsupported")
        parent=lexical.resolve(strict=True); zm.private_fs(parent); meta=parent.stat(); destination=args.output.name
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid!=os.getuid() or meta.st_mode&0o022 or destination in ("",".","..") or "/" in destination or "\\" in destination: raise StoredError("unsafe output path")
        parent_fd=os.open(parent,os.O_RDONLY|DIRECTORY|NOFOLLOW|CLOEXEC)
        try: os.stat(destination,dir_fd=parent_fd,follow_symlinks=False); raise StoredError("output destination already exists")
        except FileNotFoundError: pass
        if args.metadata_parser.resolve(strict=True)!=Path(zm.__file__).resolve(): raise StoredError("metadata parser identity mismatch")
        stage_name=f".{destination}.stage"; os.mkdir(stage_name,0o700,dir_fd=parent_fd); stage=parent/stage_name; stage_fd=os.open(stage_name,os.O_RDONLY|DIRECTORY|NOFOLLOW|CLOEXEC,dir_fd=parent_fd)
        try:
            source=stage_input(args.input,stage_fd,args.max_input_bytes); archive=os.open("archive.zip",os.O_RDONLY|NOFOLLOW|CLOEXEC,dir_fd=stage_fd)
            try: records=inspect(archive,source["size"],args); extract(archive,stage_fd,records)
            finally: os.close(archive)
            report={"schema":SCHEMA,"input":source,"entries":records,"caps":caps,"total_extracted_bytes":sum(x["size"] for x in records),"limitations":["Classic single-disk, descriptor-free, unencrypted STORED regular files and directories only; no recovery, restoration, recursion, mounting, analysis, execution, or network access."]}; payload=zm.canonical(report)
            if len(payload)>args.max_report_bytes: raise StoredError("canonical report exceeds max-report-bytes")
            create_file(stage_fd,f"{SCHEMA}.json",payload); create_file(stage_fd,"stdout.txt",b""); create_file(stage_fd,"stderr.txt",b""); os.unlink("archive.zip",dir_fd=stage_fd)
        finally: os.close(stage_fd)
        now=datetime.now(timezone.utc).isoformat().replace("+00:00","Z"); script=str(Path(__file__).resolve()); launcher=str(Path(sys.executable).resolve()); outputs=[x["path"] for x in records if x["type"]=="file"]
        metadata_parser=str(Path(zm.__file__).resolve()); spec={"schema_version":"analysis-manifest.v1","input":{"path":f"{SCHEMA}.json","detected_type":"ZIP STORED extraction report with source SHA-256"},"tool":{"name":"zip-stored","version":"1","executable":launcher,"artifacts":[{"path":script,"argv_index":1},{"path":metadata_parser,"argv_index":7}]},"argv":[launcher,script,"--input",source["path"],"--output",str(parent/destination),"--metadata-parser",metadata_parser],"environment":{},"run":{"started_at":now,"ended_at":now,"duration_ms":0,"exit_code":0,"signal":None},"stdout_path":"stdout.txt","stderr_path":"stderr.txt","outputs":outputs,"findings":[],"limitations":report["limitations"],"errors":[],"completeness":"complete","isolation_profile":PROFILE_INPROCESS_ZIP_STORED}
        spec_path=stage/"manifest-spec.json"; spec_fd=os.open(spec_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|NOFOLLOW,0o400)
        try: write_all(spec_fd,zm.canonical(spec)); os.fsync(spec_fd)
        finally: os.close(spec_fd)
        manifest=stage/"analysis-manifest.v1.json"; subprocess.run([sys.executable,str(args.manifest_cli),"create","--root",str(stage),"--spec",str(spec_path),"--output",str(manifest)],check=True); spec_path.unlink(); subprocess.run([sys.executable,str(args.manifest_cli),"verify","--root",str(stage),str(manifest)],check=True)
        for path in stage.rglob("*"): path.chmod(0o700 if path.is_dir() else 0o400)
        expected_dirs={"/".join(item["path"].rstrip("/").split("/")[:i]) for item in records for i in range(1,len(item["path"].rstrip("/").split("/"))+int(item["type"]=="directory"))}; expected=set(outputs)|{f"{SCHEMA}.json","stdout.txt","stderr.txt","analysis-manifest.v1.json"}; validate(stage,expected,expected_dirs); publish(parent_fd,stage_name,destination); stage=None; return 0
    except PublishedUnsynced as exc: stage=None; print(f"zip-stored: published with uncertain durability: {exc}",file=sys.stderr); return 3
    except (StoredError,zm.ZipMetadataError,OSError,ValueError,KeyError,struct.error,subprocess.SubprocessError) as exc: print(f"zip-stored: {exc}",file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): shutil.rmtree(stage)
        if parent_fd>=0: os.close(parent_fd)


if __name__=="__main__": sys.exit(main())
