#!/usr/bin/lua5.3

-- script to fetch and parse latest-releases.yaml from master site
-- and fetch the latest minirootfs images for all available branches

local request = require("http.request")
local cqueues = require("cqueues")
local yaml = require("lyaml")
local lfs = require("lfs")

local m = {}
m.mirror = os.getenv("MIRROR") or "https://dl-master.alpinelinux.org/alpine"

function m.fatal(...)
	m.errormsg(...)
	os.exit(1)
end

function m.fetch(url)
	local headers, stream = request.new_from_uri(url):go()
	if not headers then
		m.fatal("Error: %s: %s", url, stream)
	end
	local body = stream:get_body_as_string()
	return headers:get(":status"), body
end

function m.errormsg(...)
	local msg = string.format(...)
	io.stderr:write(string.format("%s\n", msg))
	return nil, msg
end

function m.fetch_file(url, outfile)
	local headers, stream = request.new_from_uri(url):go()
	if not headers then
		m.fatal("Error: %s: %s", url, stream)
	end
	if headers:get(":status") ~= "200" then
		m.fatal("Error: HTTP %s: %s", headers:get(":status"), url)
	end

	local partfile = string.format("%s.part", outfile)
	local f, errmsg = io.open(partfile, "w")
	if not f then
		return errormsg("Error: %s: %s:", file, errmsg)
	end
	local ok, errmsg, errnum = stream:save_body_to_file(f)
	f:close()
	if not ok then
		return errormsg("Error: %s: %s", errmsg, url)
	end
	return os.rename(partfile, outfile)
end

function m.mkdockerfile(dir, rootfsfile)
	local filename = string.format("%s/Dockerfile", dir)
	local f, err = io.open(filename, "w")
	if not f then
		m.fatal("Error: %s: %s", filename, err)
	end
	f:write(string.format('FROM scratch\nADD %s /\nCMD ["/bin/sh"]\n', rootfsfile))
	f:close()
end

function m.minirootfs_image(images)
	for _, img in pairs(images) do
		if img.flavor == "alpine-minirootfs" then
			return img
		end
	end
	return nil
end

function m.get_minirootfs(images, destdir)
	local img = m.minirootfs_image(images)
	if destdir then
		local url = string.format("%s/%s/releases/%s/%s", m.mirror, img.branch, img.arch, img.file)
		local archdir = string.format("%s/%s", destdir, img.arch)
		local ok, errmsg = lfs.mkdir(archdir)
		m.fetch_file(url, string.format("%s/%s", archdir, img.file))
		m.mkdockerfile(archdir, img.file)
		print(string.format("Downloaded: %s/%s", img.arch, img.file))
		io.stdout:flush() -- 强制刷新缓冲区，确保日志实时输出
	end
	return { version = img.version, file = img.file, sha512 = img.sha512 }
end

-- get array of minirootsfs releases --
function m.get_releases(branch, destdir)
	local arches = { "aarch64", "armhf", "armv7", "ppc64le", "riscv64", "s390x", "x86", "x86_64" }
	local t = {}
	local loop = cqueues.new()
	for _, arch in pairs(arches) do
		loop:wrap(function()
			local url = string.format("%s/%s/releases/%s/latest-releases.yaml", m.mirror, branch, arch)
			local status, body = m.fetch(url)
			if status == "200" then
				t[arch] = m.get_minirootfs((yaml.load(body)), destdir)
			end
		end)
	end
	loop:loop()
	return t
end

function m.equal_versions(releases)
	local prev = nil
	for arch, img in pairs(releases) do
		if prev == nil then
			prev = img.version
		end
		if prev ~= img.version then
			return false, arch
		end
		prev = img.version
	end
	return true
end

-- return functions as module for unit testing
if not string.match(arg[0], "fetch%-latest%-releases") then
	return m
end

local branch = arg[1] or "edge"
local destdir = arg[2] or "out"

-- 主运行逻辑包裹在循环中，防止容器执行完直接退出
while true do
	print(string.format("=== Starting fetch task for branch: %s ===", branch))
	io.stdout:flush()

	lfs.mkdir(destdir)

	local version
	local releases = m.get_releases(branch, destdir)

	if next(releases) == nil then
		print(string.format("Error: No releases found on %s/%s/releases", m.mirror, branch))
	else
		if not m.equal_versions(releases) then
			print("Error: not all versions are equal")
		else
			local f = io.open(string.format("%s/checksums.sha512", destdir), "w")
			for arch, rel in pairs(releases) do
				local line = string.format("%s  %s/%s\n", rel.sha512, arch, rel.file)
				f:write(line)
				version = rel.version
			end
			f:close()

			-- write version
			f = io.open(string.format("%s/VERSION", destdir), "w")
			f:write(version)
			f:close()
			print(string.format("=== Task completed successfully. Version: %s ===", tostring(version)))
		end
	end
	io.stdout:flush()

	-- 每次执行完毕后休眠 6 小时（21600秒），你可以根据需要调整时间
	print("Sleeping for 6 hours before next run...")
	io.stdout:flush()
	cqueues.sleep(21600)
end
