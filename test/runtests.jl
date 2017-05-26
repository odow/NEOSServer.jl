using NEOS, Base.Test

# using Compat
using MathProgBase

@testset "MPSWriter" begin
	include(joinpath(dirname(@__FILE__), "MPSWriter.jl"))
end

# Null out this method for testing
NEOS.getobjbound(m::NEOS.NEOSMathProgModel) = 0

#
# As part of the NEOS terms of use, some solvers
# 	require a valid email to be supplied.
#
# TESTING_EMAIL = readchomp(`git config --get user.email`)
TESTING_EMAIL = "odow@users.noreply.github.com"

@testset "Test NEOS Server" begin
	s = NEOSServer()
	addemail!(s, TESTING_EMAIL)
	@test s.email == TESTING_EMAIL
	addemail!(s, "")
	s = NEOSServer(email=TESTING_EMAIL)
	@test s.email == TESTING_EMAIL
	v = version(s)
	@test match(r"neos version ([0-9]+) \(.+\)", v) != nothing

	@test contains(neosHelp(s), "class NeosServer")

	_solvers = listAllSolvers(s)
	@test "milp:CPLEX:MPS" in _solvers
	@test "milp:MOSEK:MPS" in _solvers
	@test "lp:MOSEK:MPS" in _solvers
	@test "milp:SYMPHONY:MPS" in _solvers
	@test "milp:FICO-Xpress:MPS" in _solvers

	@test "Mixed Integer Linear Programming" in listCategories(s)

	_solvers = listSolversInCategory(s, :MILP)
	@test "CPLEX:MPS" in _solvers
	@test "MOSEK:MPS" in _solvers
	@test "SYMPHONY:MPS" in _solvers
	@test "FICO-Xpress:MPS" in _solvers

	j = NEOS.NEOSJob(3804943, "OfRcoMbp")
	_info = getJobInfo(s, j)
	@test _info[1] == "milp"
	@test _info[2] == "FICO-Xpress"
	@test _info[3] == "MPS"
	@test _info[4] == "Done"

	@test getJobStatus(s, j) == "Done"
	@test killJob(s, j) == "Job #3804943 is finished"

	@test getIntermediateResults(s, j) == getIntermediateResultsNonBlocking(s, j) == "Results for Job #3804943 are no longer available"
end

@testset "Test NEOSMathProgModel" begin
	m = MathProgBase.LinearQuadraticModel(NEOSSYMPHONYSolver())
	@test isa(m.solver, NEOS.NEOSSolver{NEOSSYMPHONYSolver})
	@test MathProgBase.getsolution(m) == []
	@test MathProgBase.getobjval(m) == 0.
	@test MathProgBase.getsense(m) == :Min
	MathProgBase.setsense!(m, :Max)
	@test MathProgBase.getsense(m) == :Max
	@test MathProgBase.status(m) == NEOS.NOTSOLVED
	MathProgBase.loadproblem!(m, [1. 2. 3.; 1. 1. 1.], [-1., 0., 0.], [1., 1., Inf], [0., 0., 1.], [1.25, 1.], [1.25, 1.], :Max)
	MathProgBase.setvartype!(m, [:SemiCont, :Cont, :Bin])
	@test_throws Exception NEOS.addCOLS(m, "")
	MathProgBase.setvartype!(m, [:SemiInt, :Cont, :Bin])
	@test_throws Exception NEOS.addCOLS(m, "")
end

SOLVERS = [(NEOSCPLEXSolver, :timelimit), (NEOSMOSEKSolver, :MSK_DPAR_OPTIMIZER_MAX_TIME), (NEOSSYMPHONYSolver, :time_limit), (NEOSXpressSolver, :MAXTIME)]

for (s, timelimit) in SOLVERS
	solver = s()

	@testset "Test basic solver stuff for $(typeof(solver))" begin
		@test isa(solver, NEOS.NEOSSolver)
		fields = fieldnames(solver)
		for sym in [:server, :requires_email, :solves_sos, :provides_duals,
			:template, :params, :gzipmodel, :print_results, :result_file]
			@test sym in fields
		end

		@test method_exists(NEOS.parse_status!, (typeof(solver), NEOS.NEOSMathProgModel))
		@test method_exists(NEOS.parse_objective!, (typeof(solver), NEOS.NEOSMathProgModel))
		@test method_exists(NEOS.parse_solution!, (typeof(solver), NEOS.NEOSMathProgModel))

		m = MathProgBase.LinearQuadraticModel(solver)

		m.nrow, m.ncol = 1, 2
		if solver.provides_duals
			@test method_exists(NEOS.parse_duals!, (typeof(solver), NEOS.NEOSMathProgModel))
			@test MathProgBase.getreducedcosts(m) == []
			@test MathProgBase.getconstrduals(m) == []
		else
			@test isnan(MathProgBase.getreducedcosts(m)) == [true, true;]
			@test isnan(MathProgBase.getconstrduals(m)) == [true;]
		end

		if !solver.solves_sos
			@test_throws Exception MathProgBase.addsos1!(m, [], [])
			@test_throws Exception MathProgBase.addsos2!(m, [], [])
		end

		addemail!(m, "Test")
		@test m.solver.server.email == "Test"
		addemail!(solver, TESTING_EMAIL)
		@test solver.server.email == TESTING_EMAIL


		addparameter!(solver, "key", 0)
		@test solver.params["key"] == 0
		solver.params = Dict{String, Any}()

		_solver = @eval $(s)($(timelimit)=60, email=TESTING_EMAIL)
		@test _solver.params[string(timelimit)] == 60
		@test _solver.server.email == TESTING_EMAIL

		if solver.requires_email
			addemail!(solver, "")
			@test_throws Exception linprog([-1.,0.;],sparse([2. -1.;]),'<',1.5, [-1, -Inf], [1, 0.], solver)
			addemail!(solver, TESTING_EMAIL)
		end
	end

    @testset "Testing feasible problem $(typeof(solver))" begin
	    sol = linprog([-1.,0.;],sparse([2. -1.;]),'<',1.5, [-1, -Inf], [1, 0.], solver)
	    @test sol.status == :Optimal
	    @test isapprox(sol.objval, -0.75, atol=1e-5)
	    @test  isapprox(sol.sol, [0.75, 0.;], atol=1e-5)
		if solver.provides_duals
	    	@test isapprox(sol.attrs[:lambda], [-0.5;], atol=1e-5)
	    	@test isapprox(sol.attrs[:redcost], [0., -0.5;], atol=1e-5)
		else
			@test isnan(sol.attrs[:lambda]) == [true]
	    	@test isnan(sol.attrs[:redcost]) == [true, true;]
		end

		addparameter!(solver, string(timelimit), 60)
        sol = mixintprog(-[5.,3.,2.,7.,4.;],Float64[2. 8. 4. 2. 5.;],'<',10.,:Int,-0.5,1.,solver)
		@test sol.status == :Optimal
 		@test isapprox(sol.objval, -16.0, atol=1e-6)
		@test isapprox(sol.sol, [1.0, 0.0, 0.0, 1.0, 1.0;], atol=1e-4)
	end

	@testset "Testing infeasible problem $(typeof(solver))" begin
		solver.gzipmodel=false
	    sol = linprog([1.,0.;],[-2. -1.;],'>',1., solver)
		@test (sol.status == NEOS.INFEASIBLE || sol.status == NEOS.UNBNDORINF)
	end

	@testset "Testing unbounded problem $(typeof(solver))" begin
	    solver.result_file = randstring(5)
		sol = linprog([-1.,-1.;],[-1. 2.;],'<',[0.;], solver)
	    @test (sol.status == NEOS.UNBOUNDED || sol.status == NEOS.UNBNDORINF)
		@test length(readstring(solver.result_file)) > 0
		rm(solver.result_file)
		solver.result_file = ""
    end

	@testset "Testing null problem $(typeof(solver))" begin
		solver.result_file = randstring(5)
		m = MathProgBase.LinearQuadraticModel(solver)
		MathProgBase.loadproblem!(m, Array{Int}(0,1), [0.], [Inf], [1.], [], [], :Min)
		MathProgBase.optimize!(m)
		rm(solver.result_file)
		solver.result_file = ""
	end

	!solver.solves_sos && continue
	@testset "Testing SOS problem $(typeof(solver))" begin
		m = MathProgBase.LinearQuadraticModel(solver)
		MathProgBase.loadproblem!(m, [1. 2. 3.; 1. 1. 1.], [-1., 0., 0.], [1., 1., Inf], [0., 0., 1.], [1.25, 1.], [1.25, 1.], :Max)
		MathProgBase.addsos2!(m, [1, 2, 3], [1., 2., 3.])
		@test MathProgBase.optimize!(m) == NEOS.OPTIMAL
		@test isapprox(MathProgBase.getobjval(m), 0., atol=1e-6)
		@test isapprox(MathProgBase.getsolution(m), [0.75, 0.25, 0.], atol=1e-6)

		m = MathProgBase.LinearQuadraticModel(solver)
		MathProgBase.loadproblem!(m, [1. 1. 1.], [0., 0., 0.], [1., 1., 1.], [1., 3., 2.], [0.], [1.5], :Max)
		MathProgBase.addsos1!(m, [1, 2, 3], [1., 2., 3.])
		@test MathProgBase.optimize!(m) == NEOS.OPTIMAL
		@test isapprox(MathProgBase.getobjval(m), 3., atol=1e-6)
		@test isapprox(MathProgBase.getsolution(m), [0., 1., 0.], atol=1e-6)
	end
end
