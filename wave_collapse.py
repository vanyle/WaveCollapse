import imageio.v2 as imageio
import numpy as np
import math
import random
from typing import Set, Tuple, List
import copy

class TileMap2:
    tmap = {} # Dict[(int,int), Set[int]]
    width = 0
    height = 0
    rules = {} # Dict[(int,int), Dict[int, Set[int]]]
    tile_ids: Set[int] = set()
    tile_distribution = {}

orientations = [
    (-1,-1),
    (-1,0),
    (-1,1),

    (1,-1),
    (1,0),
    (1,1),

    (0,-1),
    (0,1),
]

def createTexture(filename: str):
    return imageio.imread(filename)

def readPixel(tex,x,y,c):
    return tex[x][y][c]

def toPNG(tex, path: str):
    imageio.imwrite(path, tex)

def textureToConstraints(tex):
    w,h,_ = tex.shape

    bigPicture = np.zeros((w,h))
    colorTable = {}
    reverseColorTable = {}
    for x in range(w):
        for y in range(h):
            r = readPixel(tex,x,y,0) # / 255.0
            g = readPixel(tex,x,y,1) # / 255.0
            b = readPixel(tex,x,y,2) # / 255.0
            col = (r,g,b)
            if col not in reverseColorTable:
                vid = len(reverseColorTable)
                reverseColorTable[col] = vid
                colorTable[vid] = col
            else:
                vid = reverseColorTable[col]
            bigPicture[y][x] = vid

    return (bigPicture, colorTable)

def forceSelfSimilarity(bigImage):
    big_image_width,big_image_height = bigImage.shape

    id_conversion_table = {}
    new_id_to_old_id = {}
    s = np.zeros((big_image_width,big_image_height))

    def read_arr(bigImage,x,y):
        if x < 0: return bigImage[0][0]
        if y < 0: return bigImage[0][0]
        if x >= big_image_width: return bigImage[0][0]
        if y >= big_image_height: return bigImage[0][0]
        return bigImage[x][y]

    for x in range(big_image_width):
        for y in range(big_image_height):
            neighbours = tuple([
                read_arr(bigImage,x,y-1),
                read_arr(bigImage,x-1,y),
                read_arr(bigImage,x,y+1),
                read_arr(bigImage,x+1,y)
            ])
            vid = -1
            if neighbours in id_conversion_table:
                vid = id_conversion_table[neighbours]
            else:
                vid = len(id_conversion_table)
                id_conversion_table[neighbours] = vid
                new_id_to_old_id[vid] = read_arr(bigImage,x,y)
            s[x][y] = vid

    return (s, new_id_to_old_id)

def makeTileMap2(bigImage):
    pixelCount = 0
    big_image_width,big_image_height = bigImage.shape
    result = TileMap2()

    for ori in orientations:
        result.rules[ori] = {}

    def readArr(x,y):
        if x < 0: return bigImage[0][0]
        if y < 0: return bigImage[0][0]
        if x >= big_image_width: return bigImage[0][0]
        if y >= big_image_height: return bigImage[0][0]
        return bigImage[x][y]

    for x in range(big_image_width):
        for y in range(big_image_height):
            pixelCount += 1
            px = bigImage[x][y]
            result.tile_ids.add(px)
            if px not in result.tile_distribution:
                result.tile_distribution[px] = 0
            result.tile_distribution[px] += 1

            for ori in orientations:
                if bigImage[x][y] not in result.rules[ori]:
                    result.rules[ori][px] = set()

            if y < big_image_height-1:
                result.rules[(0,1)][px].add(readArr(x,y+1))
                if x > 0:
                    result.rules[(-1,1)][px].add(readArr(x-1,y+1))
                if x < big_image_width-1:
                    result.rules[(1,1)][px].add(readArr(x+1,y+1))
            if y > 0:
                result.rules[(0,-1)][px].add(readArr(x,y-1))
                if x > 0:
                    result.rules[(-1,-1)][px].add(readArr(x-1,y-1))
                if x < big_image_width-1:
                    result.rules[(1,-1)][px].add(readArr(x+1,y-1))
            if x > 0:
                result.rules[(-1,0)][px].add(readArr(x-1,y))
            if x < big_image_width-1:
                result.rules[(1,0)][px].add(readArr(x+1,y))


    for i in result.tile_ids:
        pI = result.tile_distribution[i] / pixelCount
        result.tile_distribution[i] = pI * math.log(pI)

    return result

def queryMap(tmap: TileMap2, pos: Tuple[int,int]) -> Set[int]:
    if pos in tmap.tmap:
        return tmap.tmap[pos].copy()
    else:
        return tmap.tile_ids.copy()

def removeFromMap(tmap: TileMap2, pos: Tuple[int,int],s: int):
    if pos not in tmap.tmap:
        tmap.tmap[pos] = tmap.tile_ids.copy()
    tmap.tmap[pos].discard(s)

def performUpdate(tmap: TileMap2,
    cpos: Tuple[int,int],
    opos: Tuple[int,int],
    ori: Tuple[int,int],
    updateStack: List[Tuple[int,int]]):

    allowedOtherPos = queryMap(tmap, opos)
    inCurrentPos = queryMap(tmap, cpos)
    updateRequired = False

    for i in allowedOtherPos:
        isAllowed = False
        for current_possible_values in inCurrentPos:
            if i in tmap.rules[ori][current_possible_values]:
                isAllowed = True
                break
        if not isAllowed:
            removeFromMap(tmap, opos, i)
            updateRequired = True

    if len(queryMap(tmap, opos)) == 0:
        # contradiction!
        return

    if updateRequired:
        updateStack.append(opos)

def updateSquare(tmap: TileMap2, pos: Tuple[int,int], stack: List[Tuple[int,int]]):
    ux,uy = pos
    width = tmap.width
    height = tmap.height

    if uy > 0:
        performUpdate(tmap, pos, (ux,uy-1), (0,-1), stack)
    if uy < height-1:
        performUpdate(tmap, pos, (ux,uy+1), (0, 1), stack)

    if ux > 0:
        performUpdate(tmap, pos, (ux-1,uy), (-1, 0), stack)
        if uy > 0:
            performUpdate(tmap, pos, (ux-1,uy-1), (-1,-1), stack)
        if uy < height-1:
            performUpdate(tmap, pos, (ux-1,uy+1), (-1, 1), stack)

    if ux < width-1:
        performUpdate(tmap, pos, (ux+1,uy), (1, 0), stack)
        if uy > 0:
            performUpdate(tmap, pos, (ux+1,uy-1), (1, -1), stack)
        if uy < height-1:
            performUpdate(tmap, pos, (ux+1,uy+1), (1, 1), stack)
    

def updateSquareRecursively(tmap: TileMap2, pos: Tuple[int,int]):
    pendingUpdate: List[Tuple[int,int]] = [pos]
    while len(pendingUpdate) > 0:
        (ux,uy) = pendingUpdate.pop()
        updateSquare(tmap, (ux,uy), pendingUpdate)

def performOneCollapseStep(tmap: TileMap2, width: int, height: int):
    tmap.width = width
    tmap.height = height

    toUpdate: Tuple[int,int]

    if len(tmap.tmap) == 0:
        toUpdate = (width // 2, height // 2)
    else:
        minIdx: Tuple[int,int] = (0,0)
        minEntro = 9999999999

        for pos in tmap.tmap:
            vals = tmap.tmap[pos]

            if len(vals) == 0: return "FAIL"
            if len(vals) <= 1: continue
            entro = 0.0
            for _ in vals:
                entro += 1
            entro += (random.random() / 2)
            if entro < minEntro:
                minEntro = entro
                minIdx = pos

        if minEntro == 9999999999:
            if len(tmap.tmap) < width * height:
                while minIdx in tmap.tmap:
                    minIdx = (
                        math.floor(random.random() * width),  
                        math.floor(random.random() * height)
                    )
            else:
                return "SUCCESS"
        toUpdate = minIdx

    if toUpdate not in tmap.tmap:
        tmap.tmap[toUpdate] = tmap.tile_ids.copy()

    tmap.tmap[toUpdate] = set(random.sample(tmap.tmap[toUpdate].copy(),1))
    updateSquareRecursively(tmap, toUpdate)
    return "OK"

def collapse(tmap: TileMap2, width: int, height: int, hook = None):
    tmap.width = width
    tmap.height = height

    mapBackup1 = copy.deepcopy(tmap.tmap) # store 2 maps to be able to rollback twice
    mapBackup2 = copy.deepcopy(tmap.tmap)
    rollbackCounter = width * height / 4
    failsOnStep = 0

    while True:
        if failsOnStep == 0:
            # store backup only if map is fresh.
            mapBackup2 = copy.deepcopy(mapBackup1)
        mapBackup1 = copy.deepcopy(tmap.tmap)

        status = performOneCollapseStep(tmap, width, height)

        if hook != None:
            hook()

        if status == "FAIL" and rollbackCounter > 0:
            if failsOnStep == 5: # fail after 5 rollbacks. We try to rollback twice.
                tmap.tmap = copy.deepcopy(mapBackup2)
            else:
                tmap.tmap = copy.deepcopy(mapBackup1)
            failsOnStep += 1
            rollbackCounter -= 1
        elif status == "SUCCESS" or status == "FAIL":
            break
        else:
            failsOnStep = 0

def toTexture(tmap: TileMap2, coloring):
    bitmap = []
    c = 0
    for i in range(tmap.width):
        for j in range(tmap.height):
            vals = None
            if (i,j) in tmap.tmap:
                vals = tmap.tmap[(i,j)]
            else:
                vals = tmap.tile_ids
            
            r = 0
            g = 0
            b = 0
            for v in vals:
                v1,v2,v3 = coloring(v)
                r += v1
                g += v2
                b += v3
            if len(vals) > 0:
                r = min(r / math.sqrt(len(vals)), 255.0)
                g = min(g / math.sqrt(len(vals)), 255.0)
                b = min(b / math.sqrt(len(vals)), 255.0)
            bitmap.append(r)
            bitmap.append(g)
            bitmap.append(b)
            bitmap.append(255)
            c += 1

    return np.array(bitmap).reshape((tmap.width, tmap.height, 4)).astype(np.uint8)

if __name__ == "__main__":
    tex = createTexture("Beach.png")

    big_picture, colorTable = textureToConstraints(tex)
    big_picture2, colorTable2 = forceSelfSimilarity(big_picture)

    tm = makeTileMap2(big_picture2)


    def coloring(vid):
        # return colorTable[int(vid)]
        return colorTable[colorTable2[int(vid)]]

    def hook():
        return
        # Hook can be used to dynamically animate the result.
        # im = toTexture(tm, coloring)
        # imageio.imwrite("Beach_output.png", im)

    collapse(tm, 50, 50, hook)


    im = toTexture(tm, coloring)
    imageio.imwrite("Beach_output.png", im)
