local Rojo = script:FindFirstAncestor("Roxlit")
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local StudioToolbarContext = Roact.createContext(nil)

return StudioToolbarContext
