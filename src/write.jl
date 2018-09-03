
"""
    open_xlsx_template(filepath::AbstractString) :: XLSXFile

Open an Excel file as template for editing and saving to another file with `XLSX.writexlsx`.

The returned `XLSXFile` instance is in closed state.
"""
@inline open_xlsx_template(filepath::AbstractString) :: XLSXFile = open_or_read_xlsx(filepath, true, true, true)

const EMPTY_EXCEL_TEMPLATE = joinpath(@__DIR__, "..", "data", "blank.xlsx")

"""
    open_empty_template(sheetname::AbstractString="") :: XLSXFile

Returns an empty, writable `XLSXFile` with 1 worksheet.

`sheetname` is the name of the worksheet, defaults to `Sheet1`.
"""
function open_empty_template(sheetname::AbstractString="") :: XLSXFile
    @assert isfile(EMPTY_EXCEL_TEMPLATE) "Couldn't find template file $EMPTY_EXCEL_TEMPLATE."
    xf = open_xlsx_template(EMPTY_EXCEL_TEMPLATE)

    if sheetname != ""
        rename!(xf[1], sheetname)
    end

    return xf
end

"""
    writexlsx(output_filepath, xlsx_file; [overwrite=false])

Writes an Excel file given by `xlsx_file::XLSXFile` to file at path `output_filepath`.

If `overwrite=true`, `output_filepath` will be overwritten if it exists.
"""
function writexlsx(output_filepath::AbstractString, xf::XLSXFile; overwrite::Bool=false)

    @assert is_writable(xf) "XLSXFile instance is not writable."
    @assert !isopen(xf) "Can't save an open XLSXFile."
    @assert all(values(xf.files)) "Some internal files were not loaded into memory. Did you use `XLSX.open_xlsx_template` to open this file?"
    if !overwrite
        @assert !isfile(output_filepath) "Output file $output_filepath already exists."
    end

    update_worksheets_xml!(xf)

    xlsx = ZipFile.Writer(output_filepath)

    # write XML files
    for f in keys(xf.files)
        if f == "xl/sharedStrings.xml"
            # sst will be generated below
            continue
        end

        io = ZipFile.addfile(xlsx, f)
        EzXML.print(io, xf.data[f])
    end

    # write binary files
    for f in keys(xf.binary_data)
        io = ZipFile.addfile(xlsx, f)
        ZipFile.write(io, xf.binary_data[f])
    end

    if !isempty(get_sst(xf))
        io = ZipFile.addfile(xlsx, "xl/sharedStrings.xml")
        print(io, generate_sst_xml_string(get_sst(xf)))
    end

    close(xlsx)

    # fix libuv issue on windows (#42)
    @static Sys.iswindows() ? GC.gc() : nothing
end

get_worksheet_internal_file(ws::Worksheet) = "xl/" * get_relationship_target_by_id(get_workbook(ws), ws.relationship_id)
get_worksheet_xml_document(ws::Worksheet) = get_xlsxfile(ws).data[ get_worksheet_internal_file(ws) ]

function set_worksheet_xml_document!(ws::Worksheet, xdoc::EzXML.Document)
    xf = get_xlsxfile(ws)
    filename = get_worksheet_internal_file(ws)
    @assert haskey(xf.data, filename) "Internal file not found for $(ws.name)."
    xf.data[filename] = xdoc
end

function generate_sst_xml_string(sst::SharedStrings) :: String
    @assert sst.is_loaded "Can't generate XML string from a Shared String Table that is not loaded."
    buff = IOBuffer()

    # TODO: <sst count="89"
    print(buff, """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst uniqueCount="$(length(sst))" xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
""")

    for s in sst.formatted_strings
        print(buff, s)
    end

    print(buff, "</sst>")
    return String(take!(buff))
end

function update_worksheets_xml!(xl::XLSXFile)
    buff = IOBuffer()

    wb = get_workbook(xl)
    for i in 1:sheetcount(wb)
        sheet = getsheet(wb, i)
        doc = get_worksheet_xml_document(sheet)
        xroot = EzXML.root(doc)

        # check namespace and root node name
        @assert get_default_namespace(xroot) == SPREADSHEET_NAMESPACE_XPATH_ARG[1][2] "Unsupported Spreadsheet XML namespace $(get_default_namespace(xroot))."
        @assert EzXML.nodename(xroot) == "worksheet" "Malformed Excel file. Expected root node named `worksheet` in worksheet XML file."

        # forces a document copy to avoid crash: munmap_chunk(): invalid pointer
        EzXML.print(buff, doc)
        doc_copy = EzXML.parsexml(String(take!(buff)))

        # deletes all elements under sheetData
        child_nodes = EzXML.findall("/xpath:worksheet/xpath:sheetData/xpath:row", EzXML.root(doc_copy), SPREADSHEET_NAMESPACE_XPATH_ARG)
        for c in child_nodes
            EzXML.unlink!(c)
        end
        c = nothing
        child_nodes = nothing

        # updates sheetData
        sheetData_node = EzXML.findfirst("/xpath:worksheet/xpath:sheetData", EzXML.root(doc_copy), SPREADSHEET_NAMESPACE_XPATH_ARG)
        spans_str = string(column_number(get_dimension(sheet).start), ":", column_number(get_dimension(sheet).stop))

        # iterates over WorksheetCache cells and write the XML
        for r in eachrow(sheet)
            ordered_column_indexes = sort(collect(keys(r.rowcells)))

            row_node = EzXML.addelement!(sheetData_node, "row")
            row_node["r"] = string(row_number(r))
            row_node["spans"] = spans_str

            # add cells to row
            for c in ordered_column_indexes
                cell = getcell(r, c)
                c_element = EzXML.addelement!(row_node, "c")

                c_element["r"] = cell.ref.name

                if cell.datatype != ""
                    c_element["t"] = cell.datatype
                end

                if cell.style != ""
                    c_element["s"] = cell.style
                end

                if cell.formula != ""
                    f_node = EzXML.addelement!(c_element, "f")
                    EzXML.setnodecontent!(f_node, cell.formula)
                end

                if cell.value != ""
                    v_node = EzXML.addelement!(c_element, "v")
                    EzXML.setnodecontent!(v_node, cell.value)
                end
            end
        end

        # updates worksheet dimension
        dimension_node = EzXML.findfirst("/xpath:worksheet/xpath:dimension", EzXML.root(doc_copy), SPREADSHEET_NAMESPACE_XPATH_ARG)
        dimension_node["ref"] = string(get_dimension(sheet))

        set_worksheet_xml_document!(sheet, doc_copy)
    end

    nothing
end

function setdata!(ws::Worksheet, cell::Cell)
    @assert is_writable(get_xlsxfile(ws)) "XLSXFile instance is not writable."
    @assert ws.cache != nothing "Can't write data to a Worksheet with empty cache."
    cache = ws.cache

    r = row_number(cell)
    c = column_number(cell)

    if !haskey(cache.cells, r)
        push!(cache.rows_in_cache, r)
        sort!(cache.rows_in_cache)
        cache.cells[r] = Dict{Int, Cell}()

        for i in 1:length(cache.rows_in_cache)
            if cache.rows_in_cache[i] == r
                cache.row_index[r] = i
            end
        end
    end
    cache.cells[r][c] = cell

    # update worksheet dimension
    ws_dimension = get_dimension(ws)

    top = row_number(ws_dimension.start)
    left = column_number(ws_dimension.start)

    bottom = row_number(ws_dimension.stop)
    right = column_number(ws_dimension.stop)

    if r < top || c < left
        top = min(r, top)
        left = min(c, left)
        set_dimension!(ws, CellRange(top, left, bottom, right))
    elseif r > bottom || c > right
        bottom = max(r, bottom)
        right = max(c, right)
        set_dimension!(ws, CellRange(top, left, bottom, right))
    end

    nothing
end

function xlsx_escape(str::AbstractString)
    if isempty(str)
        return str
    end

    buffer = IOBuffer()

    for c in str
        if c == '&'
            write(buffer, "&amp;")
        elseif c == '"'
            write(buffer, "&quot;")
        elseif c == '<'
            write(buffer, "&lt;")
        elseif c == '>'
            write(buffer, "&gt;")
        elseif c == '\''
            write(buffer, "&apos;")
        else
            write(buffer, c)
        end
    end

    return String(take!(buffer))
end

"""
Returns the datatype and value for `val` to be inserted into `ws`.
"""
function xlsx_encode(ws::Worksheet, val::AbstractString)
    if isempty(val)
        return ("", "")
    end
    sst_ind = add_shared_string!(get_workbook(ws), xlsx_escape(val))
    return ("s", string(sst_ind))
end

xlsx_encode(::Worksheet, val::Missing) = ("", "")
xlsx_encode(::Worksheet, val::Bool) = ("b", val ? "1" : "0")
xlsx_encode(::Worksheet, val::Union{Int, Float64}) = ("", string(val))
xlsx_encode(ws::Worksheet, val::Dates.Date) = ("", string(date_to_excel_value(val, isdate1904(get_xlsxfile(ws)))))
xlsx_encode(ws::Worksheet, val::Dates.DateTime) = ("", string(datetime_to_excel_value(val, isdate1904(get_xlsxfile(ws)))))
xlsx_encode(::Worksheet, val::Dates.Time) = ("", string(time_to_excel_value(val)))

function setdata!(ws::Worksheet, ref::CellRef, val::CellValue)
    t, v = xlsx_encode(ws, val.value)
    cell = Cell(ref, t, id(val.styleid), v, "")

    setdata!(ws, cell)
end

setdata!(ws::Worksheet, ref::CellRef, val::CellValueType) = setdata!(ws, ref, CellValue(ws, val))
setdata!(ws::Worksheet, ref_str::AbstractString, value) = setdata!(ws, CellRef(ref_str), value)

setdata!(ws::Worksheet, ref::CellRef, value) = error("Unsupported datatype $(typeof(value)) for writing data to Excel file. Supported data types are $(CellValueType) or $(CellValue).")

Base.setindex!(ws::Worksheet, v, ref) = setdata!(ws, ref, v)

function writetable!(sheet::Worksheet, data, columnnames; anchor_cell::CellRef=CellRef("A1"))

    # read dimensions
    col_count = length(data)
    @assert col_count == length(columnnames) "Column count mismatch between `data` ($col_count columns) and `columnnames` ($(length(columnnames)) columns)."
    @assert col_count > 0 "Can't write table with no columns."
    row_count = length(data[1])
    if col_count > 1
        for c in 2:col_count
            @assert length(data[c]) == row_count "Row count mismatch between column 1 ($row_count rows) and column $c ($(length(data[c])) rows)."
        end
    end

    anchor_row = row_number(anchor_cell)
    anchor_col = column_number(anchor_cell)

    # write table header
    for c in 1:col_count
        target_cell_ref = CellRef(anchor_row, c + anchor_col - 1)
        sheet[target_cell_ref] = string(columnnames[c])
    end

    # write table data
    for r in 1:row_count, c in 1:col_count
        target_cell_ref = CellRef(r + anchor_row, c + anchor_col - 1)
        sheet[target_cell_ref] = data[c][r]
    end
end

function Base.setindex!(sheet::Worksheet, value, row::Integer, col::Integer)
    target_cell_ref = CellRef(row, col)
    sheet[target_cell_ref] = value
end

function Base.setindex!(sheet::Worksheet, data::AbstractVector, row::Integer, cols::UnitRange{<:Integer})
    col_count = length(data)

    @assert col_count == length(cols) "Column count mismatch between `data` ($col_count columns) and column range $cols ($(length(cols)) columns)."

    for c in 1:col_count
        target_cell_ref = CellRef(row, c + first(cols) - 1)
        sheet[target_cell_ref] = data[c]
    end
end

function Base.setindex!(sheet::Worksheet, data::AbstractVector, row::Integer, c::Colon)
    col_count = length(data)

    for c in 1:col_count
        target_cell_ref = CellRef(row, c)
        sheet[target_cell_ref] = data[c]
    end
end

Base.setindex!(sheet::Worksheet, data::AbstractVector, ref_str::AbstractString) = setindex!(sheet, data, CellRef(ref_str))

function Base.setindex!(sheet::Worksheet, data::AbstractVector, index::CellRef)
    col_count = length(data)
    anchor_row = row_number(index)
    anchor_col = column_number(index)

    for c in 1:col_count
        target_cell_ref = CellRef(anchor_row, c + anchor_col - 1)
        sheet[target_cell_ref] = data[c]
    end
end

function rename!(ws::Worksheet, name::AbstractString)
    xf = get_xlsxfile(ws)
    @assert is_writable(xf) "XLSXFile instance is not writable."

    # updates XML
    xroot = xmlroot(xf, "xl/workbook.xml")
    for node in EzXML.eachelement(xroot)
        if EzXML.nodename(node) == "sheets"

            for sheet_node in EzXML.eachelement(node)
                if sheet_node["name"] == ws.name
                    # assign new name
                    sheet_node["name"] = name
                    break
                end
            end

            break
        end
    end

    # updates the new name in the worksheet instance
    ws.name = name
    nothing
end

const FILEPATH_SHEET_TEMPLATE = joinpath(@__DIR__, "..", "data", "sheet_template.xml")

addsheet!(xl::XLSXFile, name::AbstractString="") :: Worksheet = addsheet!(get_workbook(xl), name)

"""
    addsheet!(workbook, [name]) :: Worksheet

Create a new worksheet with named `name`.
If `name` is not provided, a unique name is created.

"""
function addsheet!(wb::Workbook, name::AbstractString="") :: Worksheet

    xf = get_xlsxfile(wb)
    @assert is_writable(xf) "XLSXFile instance is not writable."

    @assert isfile(FILEPATH_SHEET_TEMPLATE) "Couldn't find template file $FILEPATH_SHEET_TEMPLATE."

    if name == ""
        # name was not provided. Will find a unique name.
        i = 1
        current_sheet_names = sheetnames(wb)
        while true
            name = "Sheet$i"
            if !in(name, current_sheet_names)
                # found a unique name
                break
            end
            i += 1
        end
    end

    @assert name != ""

    # generate sheetId
    current_sheet_ids = [ ws.sheetId for ws in wb.sheets ]
    sheetId = max(current_sheet_ids...) + 1

    xdoc = EzXML.readxml(FILEPATH_SHEET_TEMPLATE)

    # generate a unique name for the XML
    local xml_filename::String
    i = 1
    while true
        xml_filename = "xl/worksheets/sheet$i.xml"
        if !in(xml_filename, keys(xf.files))
            break
        end
        i += 1
    end

    # adds doc do XLSXFile
    xf.files[xml_filename] = true # is read
    xf.data[xml_filename] = xdoc

    # adds workbook-level relationship
    # <Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>
    rId = add_relationship!(wb, xml_filename[4:end], "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet")

    # creates Worksheet instance
    ws = Worksheet(xf, sheetId, rId, name, CellRange("A1:A1"))

    # creates a mock WorksheetCache
    # because we can't write to sheet with empty cache (see setdata!(ws::Worksheet, cell::Cell))
    # and the stream should be closed
    # to indicate that no more rows will be fetched from SheetRowStreamIterator in Base.iterate(ws_cache::WorksheetCache, row_from_last_iteration::Int)
    itr = SheetRowStreamIterator(ws)
    zip_io, reader = open_internal_file_stream(xf, "[Content_Types].xml") # could be any file
    state = SheetRowStreamIteratorState(zip_io, reader, true, 0)
    close(state)
    ws.cache = WorksheetCache(CellCache(), Vector{Int}(), Dict{Int, Int}(), itr, state)

    # adds the new sheet to the list of sheets in the workbook
    push!(wb.sheets, ws)

    # updates workbook xml
    xroot = xmlroot(xf, "xl/workbook.xml")
    for node in EzXML.eachelement(xroot)
        if EzXML.nodename(node) == "sheets"

            #<sheet name="Sheet1" r:id="rId1" sheetId="1"/>
            sheet_element = EzXML.addelement!(node, "sheet")
            sheet_element["name"] = name
            sheet_element["r:id"] = rId
            sheet_element["sheetId"] = string(sheetId)

            break
        end
    end

    return ws
end

#
# Helper Functions
#


"""
    writetable(filename, data, columnnames; [overwrite], [sheetname])

`data` is a vector of columns.
`columnames` is a vector of column labels.
`overwrite` is a `Bool` to control if `filename` should be overwritten if already exists.
`sheetname` is the name for the worksheet.

Example using `DataFrames.jl`:

```julia
import DataFrames, XLSX
df = DataFrames.DataFrame(integers=[1, 2, 3, 4], strings=["Hey", "You", "Out", "There"], floats=[10.2, 20.3, 30.4, 40.5])
XLSX.writetable("df.xlsx", DataFrames.columns(df), DataFrames.names(df))
```
"""
function writetable(filename::AbstractString, data, columnnames; overwrite::Bool=false, sheetname::AbstractString="", anchor_cell::Union{String, CellRef}=CellRef("A1"))

    if !overwrite
        @assert !isfile(filename) "$filename already exists."
    end

    xf = open_empty_template(sheetname)
    sheet = xf[1]

    if isa(anchor_cell, String)
        anchor_cell = CellRef(anchor_cell)
    end

    writetable!(sheet, data, columnnames; anchor_cell=anchor_cell)

    # write output file
    writexlsx(filename, xf, overwrite=overwrite)
    nothing
end

"""
    writetable(filename::AbstractString; overwrite::Bool=false, kw...)
    writetable(filename::AbstractString, tables::Vector{Tuple{String, Vector{Any}, Vector{String}}}; overwrite::Bool=false)

Write multiple tables.

`kw` is a variable keyword argument list. Each element should be in this format: `sheetname=( data, column_names )`,
where `data` is a vector of columns and `column_names` is a vector of column labels.

Example:

```julia
import DataFrames, XLSX

df1 = DataFrames.DataFrame(COL1=[10,20,30], COL2=["Fist", "Sec", "Third"])
df2 = DataFrames.DataFrame(AA=["aa", "bb"], AB=[10.1, 10.2])

XLSX.writetable("report.xlsx", REPORT_A=( DataFrames.columns(df1), DataFrames.names(df1) ), REPORT_B=( DataFrames.columns(df2), DataFrames.names(df2) ))
```
"""
function writetable(filename::AbstractString; overwrite::Bool=false, kw...)

    if !overwrite
        @assert !isfile(filename) "$filename already exists."
    end

    xf = open_empty_template()
    is_first = true

    for (sheetname, (data, column_names)) in kw
        if is_first
            # first sheet already exists in template file
            sheet = xf[1]
            rename!(sheet, string(sheetname))
            writetable!(sheet, data, column_names)

            is_first = false
        else
            sheet = addsheet!(xf, string(sheetname))
            writetable!(sheet, data, column_names)
        end
    end

    # write output file
    writexlsx(filename, xf, overwrite=overwrite)
    nothing
end

function writetable(filename::AbstractString, tables::Vector{Tuple{String, Vector{Any}, Vector{T}}}; overwrite::Bool=false) where {T<:Union{String, Symbol}}

    if !overwrite
        @assert !isfile(filename) "$filename already exists."
    end

    xf = open_empty_template()

    is_first = true

    for (sheetname, data, column_names) in tables
        if is_first
            # first sheet already exists in template file
            sheet = xf[1]
            rename!(sheet, string(sheetname))
            writetable!(sheet, data, column_names)

            is_first = false
        else
            sheet = addsheet!(xf, string(sheetname))
            writetable!(sheet, data, column_names)
        end
    end

    # write output file
    writexlsx(filename, xf, overwrite=overwrite)
end
