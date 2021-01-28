### A Pluto.jl notebook ###
# v0.12.18

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : missing
        el
    end
end

# ╔═╡ 18cdfdc6-5437-11eb-1ff7-7387fe53bc04
begin
	ROOT_DIR = @__DIR__
	using Pkg; Pkg.activate(ROOT_DIR); Pkg.instantiate()
	using DataFrames, Plots, CSV, PlutoUI
	plotly() # Set the backend to be used by Plots.jl
	md"*Environment is set up.*"
end

# ╔═╡ 704e53d0-5436-11eb-1c05-f3305cf77335
md"""
# Correlation of scarcity time steps in the load and residual load

Every so often you read something about the importance of scarcity time steps in power system planning models, and equally often you hear about how it's difficult to predict these before running your planning model and obtaining capacities for your technologies. The reason for this is the discrepancy between the load and residual load, which is the original load minus renewable power generation.

You could assume that scarcity time steps in the load are the same as those in the residual load however, and I don't know of anyone who has actually shown that this is the case (i.e. validating the point above). Until now...

Before we continue, let's setup our environment and define some functions. 
"""

# ╔═╡ f8095c2a-5436-11eb-2a10-dd5d588749ac
begin
	ts_names = ["Load", "Solar", "WindOff", "WindOn"]
	renewables_names = ts_names[2:end]
	
	function load_time_series(country::String)
    	ts_dict = Dict(
        	ts_name => DataFrame(T = 1:8760)
        	for ts_name in ts_names
		)
		name_map = Dict(
			"Load" => "$(country)_LOAD_NT.2025.csv",
			"Solar" => "Solar_TYNDP2020_$(country).csv",
			"WindOff" => "WindOff_TYNDP2020_$(country).csv",
			"WindOn" => "WindOn_TYNDP2020_$(country).csv",
		)
		norm_factors = Dict(
			"Load" => 1000,
			"Solar" => 100,
			"WindOff" => 100,
			"WindOn" => 100,
		)
		# TODO: Get rid of hard coded 1:35 bit
		for (ts_name, ts_csv_name) in name_map
			file = joinpath(ROOT_DIR, "data", ts_csv_name)
			df = CSV.read(file, DataFrame;
				typemap=Dict(String=>Float64), 
				types=Dict(Symbol(i) => Float64 for i in 1:35),
				delim=";", decimal=','
			)
			name_pairs = [Symbol(i) => Symbol("y$(i)") for i in 1:35]
			DataFrames.rename!(df, name_pairs)
			ts_dict[ts_name] = hcat(
				ts_dict[ts_name], df[:, last.(name_pairs)] ./ norm_factors[ts_name]
			)
		end

    return ts_dict
	end
	
	function get_residual_load(ts_dict; 
			years,
			capacities=Dict(ts_name => 0.0 for ts_name in ts_names)
		)
		yidx = [Symbol("y$(i)") for i in years]
		load = Array(ts_dict["Load"][:, yidx])[:]
		
		AF = Dict(
			ts_name => Array(ts_dict[ts_name][:, yidx])[:]
			for ts_name in renewables_names
		)
		res_load = zeros(length(load))
		@simd for i in eachindex(load)
			@inbounds res_load[i] = load[i] - sum(
				capacities[ts_name] * AF[ts_name][i] for ts_name in renewables_names
			)
		end
		
		return load, res_load
	end
	
	function plot_load_and_residual_load(
			ts_dict;
			years=[1], # Years to consider
			capacities=Dict(ts_name => 0.0 for ts_name in ts_names), # RES capacities
			n::Int=100, # Number of scarcity time steps
		)
		load, res_load = get_residual_load(ts_dict; years=years, capacities=capacities)

		# Plot duration curves side by side
		load_sorted = sort(load, rev=true)
		res_load_sorted = sort(res_load, rev=true)
		p1 = Plots.plot(
			hcat(load_sorted, res_load_sorted),
			xlabel="Duration",
			ylabel="Value [MW]",
			lab=hcat("Load", "Residual Load"),
			legend=:bottomleft,
		)
		ylims1 = ylims()
		
		sortidx = sortperm(load, rev=true)[1:n]
		scatter_colours = [
			res_load[i] in res_load_sorted[1:n] ? "red" : "blue" 
			for i in sortidx
		]
		
		p2 = Plots.scatter(load[sortidx], res_load[sortidx],
			xlabel="Load [MW]",
			ylabel="Residual Load [MW]",
			lab="",
			color=scatter_colours,
			ylims=ylims1
		)
		return p1, p2
	end
	
	md"*Functions defined.*"
end

# ╔═╡ 20398d5c-54b2-11eb-292f-abeb4d935aa8
md"""
First things first, pick a country (data is from the ENTSO-E TYNDP):

**Country** = $(@bind country Select(["BE", "PT"]))
"""

# ╔═╡ 4246b5a0-54b2-11eb-1ccf-29b4f5e8e5bb
ts_dict = load_time_series(country);

# ╔═╡ 475a868e-54b2-11eb-245d-3d3ef5416837
md"""
Next, pick the number of weather + load years you want to consider:

**Years**: $(@bind y NumberField(1:35, default=1))
"""

# ╔═╡ 6936365e-54b2-11eb-3280-bbbca0e307ff
md"""
Specify installed capacities of renewable generatos in order to produce the residual load duration curve:

**Solar** [GW]: $(@bind k_solar NumberField(0:80))

**Onshore Wind** [GW]: $(@bind k_wind_on NumberField(0:80))

**Offshore Wind** [GW]: $(@bind k_wind_off NumberField(0:80))
"""

# ╔═╡ 12103490-5450-11eb-3f5a-ff54dee9895b
md"""
Finally, choose the number of scarcity time steps you want to consider. Keep in mind that if you're running an investment model over the course of a year, more than 10 scarcity time steps would be quite surprising (though of course this depends on your value of lost load).

**Number of scarcity time steps** = $(@bind n NumberField(1:100))
"""

# ╔═╡ 522a871a-5453-11eb-2451-f77e040e9e06
begin
	capacities = Dict(
		"Solar" => k_solar, "WindOn" => k_wind_on, "WindOff" => k_wind_off
	);
	years = 1:y;
	md"""
	The plot below on the left illustrates how the residual load duration curve changes with installed renewable capacity. The plot on the right shows the scarcity time steps (time steps of highest (residual) load) for the (residual) load. 
	
	Red markers in the plot below indicate a scarcity time step appears both in the load and the residual load, i.e. if you had assumed this was a scarcity time step based on the load duration curve, you would be correct also in the case of the residual load duration curve.
	"""
end

# ╔═╡ 423c65b0-544d-11eb-3c6f-f166e99e6ec0
plot(
	plot_load_and_residual_load(ts_dict, years=years, capacities=capacities, n=n)...,
	layout=(1,2),
	legend=false
)

# ╔═╡ a8be560c-54b3-11eb-0dc2-bdc20645d39b
md"""
What to make of this? Well, I noticed that increasing the solar in the case of Belgium keeps the same scarcity time steps. So that's good to know.
"""

# ╔═╡ Cell order:
# ╟─704e53d0-5436-11eb-1c05-f3305cf77335
# ╟─18cdfdc6-5437-11eb-1ff7-7387fe53bc04
# ╟─f8095c2a-5436-11eb-2a10-dd5d588749ac
# ╟─20398d5c-54b2-11eb-292f-abeb4d935aa8
# ╟─4246b5a0-54b2-11eb-1ccf-29b4f5e8e5bb
# ╟─475a868e-54b2-11eb-245d-3d3ef5416837
# ╟─6936365e-54b2-11eb-3280-bbbca0e307ff
# ╟─12103490-5450-11eb-3f5a-ff54dee9895b
# ╟─522a871a-5453-11eb-2451-f77e040e9e06
# ╟─423c65b0-544d-11eb-3c6f-f166e99e6ec0
# ╟─a8be560c-54b3-11eb-0dc2-bdc20645d39b
