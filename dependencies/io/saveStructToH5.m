function saveStructToH5(s, filename)
%SAVESTRUCTTOH5 Write a (possibly nested) scalar struct to an HDF5 file.
%   SAVESTRUCTTOH5(s, filename) recursively maps MATLAB struct fields onto
%   the HDF5 hierarchy:
%     - Scalar struct fields become HDF5 groups.
%     - Cell arrays of char/string become variable-length string datasets.
%     - char and string scalars/arrays become string datasets.
%     - Numeric and logical arrays become numeric datasets (logicals as int8).
%     - Empty fields are skipped.
%
%   The destination file is overwritten if it already exists; HDF5 datasets
%   cannot be redefined in place so a fresh file is required.
%
%   Dataset sizes match MATLAB size(val). The file includes /row_major
%   (uint8): 0 = column-major (MATLAB layout). See README.md
%   "Reading H5 outside MATLAB".
%
%   Numeric/logical datasets with at least MIN_COMPRESS_NUMEL elements are
%   written chunked with lossless deflate (gzip) compression, readable by any
%   HDF5 reader (h5py, MATLAB h5read) without extra plugins. Large mostly-NaN
%   arrays such as slap2/varFacDS shrink ~35x.

if nargin < 2 || isempty(filename)
    error('saveStructToH5:MissingFilename', 'A destination filename must be provided.');
end
if ~isstruct(s) || ~isscalar(s)
    error('saveStructToH5:UnsupportedInput', 'Input must be a scalar struct.');
end

if exist(filename, 'file')
    delete(filename);
end

writeGroup(filename, '', s);
info = h5info(filename);
if isempty(info.Datasets) || ~any(strcmp({info.Datasets.Name}, 'row_major'))
    h5create(filename, '/row_major', [1 1], 'Datatype', 'uint8');
end
h5write(filename, '/row_major', uint8(0));
end


function writeGroup(filename, basePath, s)
%WRITEGROUP Recursively write each field of struct s under basePath.
if ~isstruct(s) || ~isscalar(s)
    error('saveStructToH5:UnsupportedStruct', ...
        'Only scalar structs are supported (at %s).', emptyPathDisplay(basePath));
end

fields = fieldnames(s);
for ix = 1:numel(fields)
    fname = fields{ix};
    path = [basePath '/' fname];
    writeValue(filename, path, s.(fname));
end
end


function writeValue(filename, path, val)
%WRITEVALUE Write a single value to the HDF5 path based on its MATLAB type.
if isstruct(val)
    if ~isscalar(val)
        error('saveStructToH5:NonScalarStruct', ...
            'Non-scalar structs are not supported (at %s).', path);
    end
    writeGroup(filename, path, val);
    return;
end

if iscell(val)
    if isempty(val)
        return;
    end
    isTextCell = all(cellfun(@(x) ischar(x) || isstring(x) || isempty(x), val(:)));
    if ~isTextCell
        error('saveStructToH5:UnsupportedCell', ...
            'Only cell arrays of char/string are supported (at %s).', path);
    end
    sval = strings(size(val));
    for k = 1:numel(val)
        if isempty(val{k})
            sval(k) = "";
        else
            sval(k) = string(val{k});
        end
    end
    h5create(filename, path, size(sval), 'Datatype', 'string');
    h5write(filename, path, sval);
    return;
end

if ischar(val)
    h5create(filename, path, [1 1], 'Datatype', 'string');
    h5write(filename, path, string(val));
    return;
end

if isstring(val)
    sz = size(val);
    if isscalar(val)
        sz = [1 1];
    end
    h5create(filename, path, sz, 'Datatype', 'string');
    h5write(filename, path, val);
    return;
end

if islogical(val)
    if isempty(val)
        return;
    end
    val = int8(val);
    cArgs = compressionArgs(size(val), 1);
    h5create(filename, path, size(val), 'Datatype', 'int8', cArgs{:});
    h5write(filename, path, val);
    return;
end

if isnumeric(val)
    if isempty(val)
        return;
    end
    dtype = class(val);
    val = gather(val);          % collect gpuArray / codistributed
    sz  = size(val);
    % Round-trip through cast to materialize a plain array of the declared
    % class without applying per-element arithmetic.
    plainVal = cast(val, dtype);
    bytesPerElement = numel(typecast(plainVal(1), 'uint8'));
    cArgs = compressionArgs(sz, bytesPerElement);
    h5create(filename, path, sz, 'Datatype', dtype, cArgs{:});
    h5write(filename, path, plainVal);
    return;
end

error('saveStructToH5:UnsupportedType', ...
    'Unsupported value type ''%s'' at %s.', class(val), path);
end


function args = compressionArgs(sz, bytesPerElement)
%COMPRESSIONARGS h5create arguments for chunked deflate compression.
%   Small datasets are written contiguous (no arguments): chunking overhead
%   outweighs any saving. Deflate level 4 without shuffle measured best on
%   slap2/varFacDS (2.19 GB -> 0.06 GB, ~4 s per write).
MIN_COMPRESS_NUMEL = 4096;
DEFLATE_LEVEL = 4;
if prod(sz) < MIN_COMPRESS_NUMEL
    args = {};
    return;
end
args = {'Deflate', DEFLATE_LEVEL, 'ChunkSize', chooseChunkSize(sz, bytesPerElement)};
end


function chunk = chooseChunkSize(sz, bytesPerElement)
%CHOOSECHUNKSIZE Chunk of at most ~4 MB, shrinking trailing dimensions first
%   so chunks stay contiguous along MATLAB's leading (fastest) dimensions,
%   e.g. one rows x cols frame per chunk for rows x cols x frames arrays.
TARGET_BYTES = 4e6;
chunk = sz;
for d = numel(chunk):-1:1
    while prod(chunk) * bytesPerElement > TARGET_BYTES && chunk(d) > 1
        chunk(d) = ceil(chunk(d) / 2);
    end
end
end


function s = emptyPathDisplay(basePath)
if isempty(basePath)
    s = '/';
else
    s = basePath;
end
end
