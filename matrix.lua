local pi = math.pi
local matrix = {}
local mt 

mt = {
    __call = function (self, x, y)
        return self.v11*x + self.v12*y + self.v13,
               self.v21*x + self.v22*y + self.v23
   end;
    __mul = function(a, b)
        local t = setmetatable({
            v11 = a.v11*b.v11 + a.v12*b.v21 + a.v13*b.v31; 
            v12 = a.v11*b.v12 + a.v12*b.v22 + a.v13*b.v32;
            v13 = a.v11*b.v13 + a.v12*b.v23 + a.v13*b.v33;
            v21 = a.v21*b.v11 + a.v22*b.v21 + a.v23*b.v31;
            v22 = a.v21*b.v12 + a.v22*b.v22 + a.v23*b.v32;
            v23 = a.v21*b.v13 + a.v22*b.v23 + a.v23*b.v33;
            v31 = a.v31*b.v11 + a.v32*b.v21 + a.v33*b.v31;
            v32 = a.v31*b.v12 + a.v32*b.v22 + a.v33*b.v32;
            v33 = a.v31*b.v13 + a.v32*b.v23 + a.v33*b.v33;
        }, mt)
        return t
    end;
}

matrix.identity = function()
    return function(x, y)
        return x, y
    end
end

matrix.trans = function (dx,dy)
    return setmetatable({
        v11 = 1; v12 = 0; v13 = dx;
        v21 = 0; v22 = 1; v23 = dy;
        v31 = 0; v32 = 0; v33 =  1;
    }, mt)
end

matrix.rotate = function(rot)
    rot = rot / 180 * pi
    return setmetatable({
        v11 = math.cos(rot); v12 = -math.sin(rot); v13 = 0;
        v21 = math.sin(rot); v22 =  math.cos(rot); v23 = 0;
        v31 = 0            ; v32 = 0             ; v33 = 1;
    }, mt)
end

matrix.scale = function (sx,sy)
    return setmetatable({
        v11 = sx; v12 =  0; v13 = 0;
        v21 =  0; v22 = sy; v23 = 0;
        v31 =  0; v32 =  0; v33 = 1;
    }, mt)
end

return matrix

