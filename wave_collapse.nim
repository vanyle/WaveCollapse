##[

Written in Nim 1.6.4 (Nim version > 1.6)

This code requires stbi to be installed to load / save .png files.
You can install it using: `nimble install stb_image`

Compile using:
`nim c -d:release wave_collapse.nim`

Run with:
`./wave_collapse`

Implementation of the wave collapse algorithm in Nim.
Support for a 2d (and 1d version if you set height to 1)

For more information for what the wave collapse algorithm is and how it works, read this:
https://github.com/mxgmn/WaveFunctionCollapse

Simplest usage example

.. code-block:: nim
    var tex = createTexture("SomeImage.png")
    var (big_picture, colorTable) = tex.textureToConstraints()
    var tm = makeTileMap2(big_picture)
    tm.collapse(200, 200)
    var wave_collapse_texture = tm.toTexture((id) => colorTable[id])

    # you can draw wave_collapse_texture.
    # you can also use tm.toTexture() or tm.toArray() !


Note that the solver we use for the constraints can try solve any Wang Tile patterns (but may fail,
we are not doing the halting problem.) This means that by cleverly renumbering ids, we can implement any
set of constraints.

More about wang tiles: https://en.wikipedia.org/wiki/Wang_tile

If you want to have "self-similarity", that is to say every 3x3 piece of the output image
can be found inside the origin image (these are stronger constraints), you need to do this:

.. code-block:: nim
    var tex = createTexture("SomeImage.png")
    var (big_picture, colorTable) = tex.textureToConstraints()

    # renumber the tiles to harden the constraints.
    # This can increase the total number of ids by (old_id_count)^9
    # Be careful when using this as you might run into memory issues later if you create too many new ids.
    # the number of ids generated is `tm.tile_ids.len`
    var (big_picture2, colorTable2) = forceSelfSimilarity(big_picture)

    var tm = makeTileMap2(big_picture)
    # same as above ...


]##

import sets, tables, random, sequtils, strformat, os, math, hashes, sugar


# nimble install stb_image
import stb_image/read as stbi
import stb_image/write as stbiw


type

    Orientation* = enum
        TopRight
        Left
        TopLeft
        Top

        BottomLeft
        Right
        BottomRight
        Bottom

    Vec3 = object
        x: float32
        y: float32
        z: float32

    Texture* = ref object
        width: int
        height: int
        data: seq[byte]

    ## Contains the tiles needed for the 2d wave-collapse algorithm.
    TileMap2* = object
        ## Sparse table containing for each position a set of possible ids at that spot.
        ## If the id is not in the table, every spot is allowed.
        # This is done for memory efficiency reasons when generating large grids
        map*: Table[tuple[x:int,y:int],HashSet[int]]
        width*: int
        height*: int

        # List of constraints.
        # Orientation -> int (id1) -> set of allowed ids
        rules*: Table[Orientation,Table[int,HashSet[int]]]

        # Cache for faster computation of stuff
        tile_ids*: HashSet[int]
        tile_distribution*: Table[int, float]

const BLACK = Vec3(x:0,y:0,z:0)
const WHITE = Vec3(x:1,y:1,z:1)

proc hash*(a: Vec3) : Hash =
    result = a.x.hash !& a.y.hash !& a.z.hash
    result = !$result

proc readPixel *(t: Texture, x, y: int, c: int): byte {.inline.} =
    return t.data[c + 4*(x + t.width.int*y)]

proc createTexture *(filename: string): Texture =
    ## Create a texture from an image file.
    result = new(Texture)
    assert fileExists(filename), fmt"Unable to create a texture from {filename.string}, because it doesn't exist !"
    var width, height, channels: int
    var data = stbi.load(filename, width, height, channels, stbi.Default)

    # pad data so that there are 4 channels
    if channels < 4:
        var cdata = newSeq[byte](width * height * 4)
        var idx = 0
        for i in 0..<width*height:
                for c in 0..<channels:
                    cdata[c + 4*i] = (data[idx])
                    idx += 1
                for c in 0..<(4 - channels):
                    cdata[channels + c + 4*i] = 255 # pad with white

        result.data = cdata
    elif channels > 4:
        var cdata = newSeq[byte](width * height * 4)
        # discard additional channels
        for i in 0..<(width*height):
                for c in 0..<4:
                    cdata[c + 4*i] = (data[c + channels*i])
        result.data = cdata
    else:
        result.data = data

    assert result.data.len == 4 * width * height, fmt"Image {filename.string} was incorrectly loaded, size is {result.data.len} instead of 4 * {width} * {height} = {4*width*height}"

    result.width = width
    result.height = height

proc createTexture *(width: int, height: int, data: seq[byte] = @[]): Texture =
    ## Create an empty texture of the size provided.
    ## If you provide `data`, it will we used as the content of the texture.
    ## In this case, you must have `data.len == 4 * width * height`, with 4 bytes
    ## per pixels for the red, green, blue and alpha channels.
    result = new(Texture)
    result.width = width
    result.height = height
    if data.len != 0:
        assert data.len == 4 * width * height
        result.data = data
    else:
        result.data = newSeq[byte](width * height * 4)

proc toPNG*(t: Texture, path: string) =
    ## Save a texture to a `.png` image located at the given path.
    ## If a file already exists at the location provided, it will be overwritten.
    stbiw.writePNG(path, t.width.int, t.height.int, 4, t.data)

proc textureToConstraints*(t: Texture): (seq[seq[int]], Table[int, Vec3]) =
    var bigPicture: seq[seq[int]] = newSeqWith[seq[int]](t.height, newSeq[int](t.width))
    var colorTable: Table[int, Vec3]
    var reverseColorTable: Table[Vec3, int]

    for x in 0..<t.width:
        for y in 0..<t.height:
            # create a rule set based on the red channel of an image
            let r = t.readPixel(x,y, 0).float
            let g = t.readPixel(x,y, 1).float
            let b = t.readPixel(x,y, 2).float
            let col = Vec3(x: r / 255.0, y: g / 255.0, z: b / 255.0)
            var id = -1
            if col notin reverseColorTable:
                id = colorTable.len
                reverseColorTable[col] = id
                colorTable[id] = col
            else:
                id = reverseColorTable[col]

            bigPicture[y][x] = id
    return (bigPicture, colorTable)


proc forceSelfSimilarity*(big_image: seq[seq[int]]): (seq[seq[int]], Table[int,int]) =
    ## Change numbers inside big_image so that the constraints
    ## imposted are stronger (they require 3x3 self-similarity in the output)
    ## To recover the original ids, you can use the table return that maps the new ids to the old ids.
    ## The function obtain from the table is surjective and usually not injective.
    ## Calling this can greatly increase the number of ids, so be careful with you memory usage!
    ## I would recommend using this only when big_image contains 4 different numbers inside (like wall, air, spike and path or something)
    assert big_image.len > 0
    let big_img_width = big_image.len
    let big_img_height = big_image[0].len

    var id_conversion_table: Table[seq[int],int]
    var new_id_to_old_id: Table[int,int]
    var s: seq[seq[int]] = newSeqWith[seq[int]](big_img_width, newSeq[int](big_img_height))

    proc read_arr(big_image: seq[seq[int]], x: int, y: int): int =
        if x < 0: return big_image[0][0] # assume outside is similar to edge.
        if x >= big_img_width: return big_image[0][0]
        if y < 0: return big_image[0][0]
        if y >= big_img_height: return big_image[0][0]
        return big_image[x][y]

    for x in 0..<big_image.len:
        assert big_image[x].len == big_img_height
        for y in 0..<big_image[x].len:
            var neighbours: seq[int] = @[
                #read_arr(big_image, x-1, y-1),
                read_arr(big_image, x, y-1),
                #read_arr(big_image, x+1, y-1),

                read_arr(big_image, x-1, y),
                read_arr(big_image, x, y),
                read_arr(big_image, x+1, y),

                #read_arr(big_image, x-1, y+1),
                read_arr(big_image, x, y+1),
                #read_arr(big_image, x+1, y+1)
            ]
            var id = -1
            if neighbours in id_conversion_table:
                id = id_conversion_table[neighbours]
            else:
                id = id_conversion_table.len
                id_conversion_table[neighbours] = id
                new_id_to_old_id[id] = read_arr(big_image, x, y)
            s[x][y] = id


    return (s, new_id_to_old_id)

proc makeTileMap2*(bigImage: seq[seq[int]]): TileMap2 =
    ## Generate the correct set of rules based on the bigimage.
    ## The map generated will locally ressemble big_image
    ## inside the map generated will be found inside the big_image.

    assert bigImage.len > 0
    var pixelCount = 0
    let big_img_width = bigImage.len
    let big_img_height = bigImage[0].len

    for ori in Orientation:
        result.rules[ori] = initTable[int, HashSet[int]]()

    proc readArr(x: int, y: int): int =
        if x < 0: return bigImage[0][0] # assume outside is similar to edge.
        if x >= big_img_width: return bigImage[0][0]
        if y < 0: return bigImage[0][0]
        if y >= big_img_height: return bigImage[0][0]
        return bigImage[x][y]

    for x in 0..<bigImage.len:
        assert bigImage[x].len == big_img_height # Make sure a rectangle array is provided.

        for y in 0..<bigImage[x].len:
            inc pixelCount # count total pixel count

            result.tile_ids.incl(bigImage[x][y]) # list ids

            if bigImage[x][y] notin result.tile_distribution:
                result.tile_distribution[bigImage[x][y]] = 0.0
            result.tile_distribution[bigImage[x][y]] += 1.0 # needed to compute entropy later

            for ori in Orientation:
                if bigImage[x][y] notin result.rules[ori]:
                    result.rules[ori][bigImage[x][y]] = initHashSet[int]()

            # Compute rules
            if y < bigImage[x].len-1:
                result.rules[Top][bigImage[x][y]].incl readArr(x,y+1)
                if x > 0:
                    result.rules[TopLeft][bigImage[x][y]].incl readArr(x-1,y+1)
                if x < bigImage.len-1:
                    result.rules[TopRight][bigImage[x][y]].incl readArr(x+1,y+1)
            if x < bigImage.len-1:
                result.rules[Right][bigImage[x][y]].incl readArr(x+1,y)
            if x > 0:
                result.rules[Left][bigImage[x][y]].incl readArr(x-1,y)
            if y > 0:
                result.rules[Bottom][bigImage[x][y]].incl readArr(x,y-1)
                if x < bigImage.len-1:
                    result.rules[BottomRight][bigImage[x][y]].incl readArr(x+1,y-1)
                if x > 0:
                    result.rules[BottomLeft][bigImage[x][y]].incl readArr(x-1,y-1)

    # entropy = - sum p_i log(p_i), where p_i is proportional to tile_distribution[i]
    # we convert the tile_distribution to entropy so that it's cached.
    for i in result.tile_ids:
        var pI = result.tile_distribution[i] / pixelCount.float
        result.tile_distribution[i] = pI * ln(pI)

proc sample(rng: var Rand, s: HashSet[int]): int =
    var c = 0
    var r = rng.rand(s.len-1)
    for i in s:
        if c == r:
            return i
        inc c


type MapStatus* = enum
    WaveCollapse_InProgress
    WaveCollapse_Success
    WaveCollapse_Fail

proc queryMap(map: var TileMap2,pos: (int,int)): HashSet[int] =
    if pos in map.map:
        return map.map[pos]
    else:
        return map.tile_ids

proc removeFromMap(map: var TileMap2, pos: (int,int), s: int) =
    if pos notin map.map:
        map.map[pos] = map.tile_ids
    map.map[pos].excl s

# helper function to do propagation. The propagation is done using the set intersection
proc performUpdate(map: var TileMap2,currentPos: (int,int), otherPos: (int,int), ori: Orientation, s: var MapStatus, updateStack: var seq[(int,int)]) =
    # If a neighbourg gets changed, add it to the pending update list.

    let allowedOtherPos = map.queryMap(otherPos)
    let inCurrentPos = map.queryMap(currentPos)
    var updateRequired = false

    for i in allowedOtherPos:
        # Check if there is a rule that allows i.
        var isAllowed = false
        for current_possible_value in inCurrentPos:
            if i in map.rules[ori][current_possible_value]:
                isAllowed = true
                break
        if not isAllowed:
            map.removeFromMap(otherPos,i)
            updateRequired = true


    if map.queryMap(otherPos).len == 0:
        # We got a contradiction, clear the queue and rollback!
        updateStack = @[]
        s = WaveCollapse_Fail
        return

    if updateRequired:
        updateStack.add otherPos

proc updateSquare*(map: var Tilemap2, pos: (int,int), r: var MapStatus, stack: var seq[(int,int)]) =
    let (ux,uy) = pos
    let width = map.width
    let height = map.height

    if uy > 0:
        map.performUpdate((ux,uy), (ux,uy-1), Bottom, r, stack)
    if uy < height-1:
        map.performUpdate((ux,uy), (ux,uy+1), Top, r, stack)

    if ux > 0:
        map.performUpdate((ux,uy), (ux-1,uy), Left, r, stack)
        if uy > 0:
            map.performUpdate((ux,uy), (ux-1,uy-1), BottomLeft, r, stack)
        if uy < height-1:
            map.performUpdate((ux,uy), (ux-1,uy+1), TopLeft, r, stack)
    if ux < width-1:
        map.performUpdate((ux,uy), (ux+1,uy), Right, r, stack)
        if uy > 0:
            map.performUpdate((ux,uy), (ux+1,uy-1), BottomRight, r, stack)
        if uy < height-1:
            map.performUpdate((ux,uy), (ux+1,uy+1), TopRight, r, stack)

proc updateSquareRecursively*(map: var Tilemap2, pos:(int,int), r: var MapStatus) =
    var pendingUpdate: seq[(int,int)] = @[pos]
    while pendingUpdate.len > 0:
        var (ux,uy) = pendingUpdate.pop()
        #echo (ux,uy)," -> ", map.map[(ux,uy)]
        # Apply the rules to reduce possible values of neighbourgs.
        map.updateSquare((ux,uy), r, pendingUpdate)

proc performOneCollapseStep*(map: var TileMap2, width: int, height: int, rng: var Rand = initRand(rand(int.high))): MapStatus =
    ## Useful to generate collapse gifs to demo the algorithm.
    ## Use `collapse` to produce the complete tilemap with one function
    ## Return false in case of failure.
    result = WaveCollapse_InProgress
    map.width = width
    map.height = height
    var toUpdate: (int,int)

    # Pick the tile with lowest entropy.
    if map.map.len == 0: # start with top-left
        toUpdate = (width div 2,height div 2)
    else:
        var minIdx: (int,int) = (0,0)
        var minEntro = high(float)

        for pos,vals in map.map:
            if vals.len == 0: return WaveCollapse_Fail
            if vals.len <= 1: continue # need at least a free square.
            var entro = 0.0
            for v in vals:
                entro += 1 # map.tile_distribution[v]
            entro += rng.rand(0.5)
            if entro < minEntro:
                minEntro = entro
                minIdx = pos
        if minEntro == high(float):
            if map.map.len < width*height:
                # no free squares found, we pick a square that's outside of the map.
                # This should not be a bottleneck as there should be no case where only 1 or 2 full tiles
                # remain due to the way propagation works.
                while minIdx in map.map:
                    minIdx = (rng.rand(width - 1), rng.rand(height - 1))
            else:
                return WaveCollapse_Success

        toUpdate = minIdx # Pick the square with multiple options and the highest entropy.

    # We remove a possible state at random from the tile we want to update.
    if toUpdate notin map.map:
        map.map[toUpdate] = map.tile_ids

    var el = sample(rng, map.map[toUpdate])
    #echo map.map[toUpdate]," -> {",el,"}"
    
    map.map[toUpdate] = toHashSet([el])
    map.updateSquareRecursively(toUpdate, result)


proc defaultHook() = discard
proc collapse*(map: var TileMap2, width: int, height: int, hook: proc() = defaultHook, seed: int64 = 0) =
    ## Collapses the wave by filling with TileMap while respecting the constaints.
    ## This function uses `random`. You can give a seed for deterministic results.
    ##
    ## This can be very ressource hunger and take several seconds to complete based
    ## on the complexity of the constraints, so don't put this in the render thread!
    ##
    ## Also note that this function can fail when we run into contradictions when trying to solve
    ## the constraints. In this case, you need to rerun the function and try to give less strict
    ## constraints or just a smaller width/height. We try to reduce the failure rate as much as possible
    ## but some sets of constraints are just hard to solve.
    ##
    ## For animations, you can provide a hook that will be called at each big deduction step of the algorithm.
    var rng: Rand
    if seed == 0:
        rng = initRand(rand(int.high))
    else:
        rng = initRand(seed)

    map.width = width
    map.height = height

    var rollbackCounter: int = width * height

    #[
    # Max = 3 rollbacks (Ctrl-Z)
    # Very memory intensive. Maybe only store uncertain tiles that can change?
    let rollbackSize = 3

    var rollbackStack = @[map.map]

    # store the number of generation attempts from a given position.
    # when that number reaches 5, an additional level of rollback is performed.
    # If no more rollback are available, we fail.
    var triesStack = @[0]
    for i in 0..<rollbackSize-1: rollbackStack.add(map.map)
    var rollbackPosition = rollbackStack.len-1

    proc rollbackMap() =
        map.map = rollbackStack[rollbackPosition]
        rollbackPosition -= 1
    proc editMap() =
        # shift the stack
        rollbackPosition += 1
        rollbackPosition = rollbackPosition mod rollbackStack.len
        rollbackStack[rollbackPosition] = map.map
        inc triesStack[rollbackPosition]
    ]#

    # backup the map in case we run into a contradiction because of the pick.
    var mapBackup1 = map.map # store 2 maps to be able to rollback twice
    var mapBackup2 = map.map
    var failsOnStep = 0

    while true:
        if failsOnStep == 0:
            # store backup only if map is fresh.
            mapBackup2 = mapBackup1
        mapBackup1 = map.map

        var status = performOneCollapseStep(map, width, height, rng)
        if status == WaveCollapseFail and rollbackCounter > 0:
            if failsOnStep == 5: # fail after 5 rollbacks. We try to rollback twice.
                map.map = mapBackup2
            else:
                map.map = mapBackup1

            inc failsOnStep
            dec rollbackCounter
        elif status == WaveCollapse_Success or status == WaveCollapseFail:
            break
        else:
            failsOnStep = 0

        hook()


    #echo "Done!"
    #for x in 0..<width:
        #for y in 0..<height:
            #var s = $map.map[(width-x-1,y)]
            #stdout.write s.align(6)
        #stdout.write "\n"
    #echo fmt"{width} * {height} = {width*height} ; map.len = {map.map.len}"
    #echo "Pick count: ",pickCount

proc addConstraint*(map: var TileMap2, x: int, y:int, values: HashSet[int]): MapStatus =
    ## Enforce a constraint on the values taken by the tilemap.
    ## More precisly, it forces the point (`x`,`y`) to have an id contained in the set `values`
    ##
    ## Return `WaveCollapse_Fail` if the contraint cannot be met (this is deterministic.)
    map.map[(x,y)] = values

    # Propagate the constraint to get its consequences.
    var pendingUpdate = @[(x,y)]

    while pendingUpdate.len > 0:
        var (ux,uy) = pendingUpdate.pop()
        #echo (ux,uy)," -> ", map.map[(ux,uy)]
        # Apply the rules to reduce possible values of neighbourgs.
        map.updateSquare((ux,uy), result, pendingUpdate)

proc pick(s: HashSet[int]): int =
    for i in s: return i
    return 0


proc defaultColors(id: int): Vec3 =
    # Not the greatest default colors but at least, there's something
    if id == 0: return BLACK
    if id == 1: return WHITE
    return Vec3(x: id / high(int), y: 0, z: 1)

proc isValid*(map: TileMap2): bool =
    ## Returns true if the collapse function managed to fill all the squares of the tilemap
    ## while fulfilling all the constraints provided.
    ## Returns false if the collapse function was not called yet or if the collapse function failed
    ## to find a valid tile to put in a given position.
    ##
    ## This function is slow (O(size of tilemap)), cache its result!
    for k,v in map.map:
        if v.len != 1: return false
    return true

proc toArray*(map: TileMap2): seq[seq[int]] =
    var s: seq[seq[int]] = newSeqWith[seq[int]](map.width, newSeq[int](map.height))
    for i in 0..<map.width:
        for j in 0..<map.height:
            s[i][j] = map.map[(i,j)].pick()

    return s

proc toTexture*(map: TileMap2, coloring: proc(id: int): Vec3 = defaultColors): Texture =
    ## Convert the map to a texture with the given coloring.
    ## Useful to quickly visualize the result produced by a given ruleset.

    var bitmap: seq[byte] = newSeq[byte](4 * map.width * map.height)
    var c = 0
    for i in 0..<map.width:
        for j in 0..<map.height:
            let vals = if (i,j) in map.map: map.map[(i,j)] else: map.tile_ids
            
            var r,g,b = 0.0
            for v in vals:
                let color_vec = coloring(v)
                r += color_vec.x
                g += color_vec.y
                b += color_vec.z
            r = min(r / sqrt(vals.len.float), 1.0)
            g = min(g / sqrt(vals.len.float), 1.0)
            b = min(b / sqrt(vals.len.float), 1.0)

            bitmap[4*c + 0] = (r*255).byte
            bitmap[4*c + 1] = (g*255).byte
            bitmap[4*c + 2] = (b*255).byte
            bitmap[4*c + 3] = 255
            inc c

    return createTexture(map.width, map.height, bitmap)


when isMainModule:
    var tex = createTexture("Beach.png")
    var (big_picture, colorTable) = tex.textureToConstraints()
    var (big_picture2, colorTable2) = forceSelfSimilarity(big_picture)

    var tm = makeTileMap2(big_picture2)
    tm.collapse(50, 50)
    var wave_collapse_texture = tm.toTexture((id) => colorTable[colorTable2[id]])
    wave_collapse_texture.toPNG("Beach_output.png")

