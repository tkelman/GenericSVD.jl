module GenericSVD

import Base: SVD

include("utils.jl")
include("bidiagonalize.jl")

Base.svdfact!(X::AbstractMatrix; thin=true) = generic_svdfact!(X; thin=thin)
Base.svdvals!(X::AbstractMatrix) = generic_svdvals!(X)

function generic_svdfact!(X::AbstractMatrix; sorted=true, thin=true)
    m,n = size(X)
    t =false
    if m < n
        m,n = n,m
        X = X'
        t = true
    end
    B,P = bidiagonalize_tall!(X)
    U,Vt = full(P,thin=thin)
    U,S,Vt = svd!(B,U,Vt)
    for i = 1:n
        if signbit(S[i])
            S[i] = -S[i]
            for j = 1:n
                Vt[i,j] = -Vt[i,j]
            end
        end
    end
    if sorted
        I = sortperm(S,rev=true)
        S = S[I]
        U = U[:,I]
        Vt = Vt[I,:]
    end
    t ? SVD(Vt',S,U') : SVD(U,S,Vt)
end

function generic_svdvals!(X::AbstractMatrix; sorted=true)
    m,n = size(X)
    if m < n
        X = X'
    end
    B,P = bidiagonalize_tall!(X)
    S = svd!(B)[2]
    for i = eachindex(S)
        if signbit(S[i])
            S[i] = -S[i]
        end
    end
    sorted ? sort!(S,rev=true) : S
end


"""
Tests if the B[i-1,i] element is approximately zero, using the criteria
```math
    |B_{i-1,i}| ≤ ɛ*(|B_{i-1,i-1}| + |B_{i,i}|)
```
"""
function offdiag_approx_zero(B::Bidiagonal,i,ɛ)
    iszero = abs(B.ev[i-1]) ≤ ɛ*(abs(B.dv[i-1]) + abs(B.dv[i]))
    if iszero
        B.ev[i-1] = 0
    end
    iszero
end


"""
Generic SVD algorithm:

This finds the lowest strictly-bidiagonal submatrix, i.e. n₁, n₂ such that
```
     [ d ?           ]
     [   d 0         ]
  n₁ [     d e       ]
     [       d e     ]
  n₂ [         d 0   ]
     [           d 0 ]
```
Then applies a Golub-Kahan iteration.
"""
function svd!{T<:Real}(B::Bidiagonal{T}, U=nothing, Vt=nothing, ɛ::T = eps(T))
    n = size(B, 1)
    n₂ = n

    maxB = max(maxabs(B.dv),maxabs(B.ev))

    if istriu(B)
        while true
            @label mainloop

            while offdiag_approx_zero(B,n₂,ɛ)
                n₂ -= 1
                if n₂ == 1
                    @goto done
                end
            end



            n₁ = n₂ - 1
            # check for diagonal zeros
            if abs(B.dv[n₁]) ≤ ɛ*maxB
                svd_zerodiag_row!(U,B,n₁,n₂)
                @goto mainloop
            end
            while n₁ > 1 && !offdiag_approx_zero(B,n₁,ɛ)
                n₁ -= 1
                # check for diagonal zeros
                if abs(B.dv[n₁]) ≤ ɛ*maxB
                    svd_zerodiag_row!(U,B,n₁,n₂)
                    @goto mainloop
                end
            end

            if abs(B.dv[n₂]) ≤ ɛ*maxB
                svd_zerodiag_col!(B,Vt,n₁,n₂)
                @goto mainloop
            end


            d₁ = B.dv[n₂-1]
            d₂ = B.dv[n₂]
            e  = B.ev[n₂-1]

            s₁, s₂ = svdvals2x2(d₁, d₂, e)
            # use singular value closest to sqrt of final element of B'*B
            h = hypot(d₂,e)
            shift = abs(s₁-h) < abs(s₂-h) ? s₁ : s₂
            svd_gk!(B, U, Vt, n₁, n₂, shift)
        end
    else
        throw(ArgumentError("lower bidiagonal version not implemented yet"))
    end
    @label done
    U, B.dv, Vt
end


"""
Sets B[n₁,n₁] to zero, then zeros out row n₁ by applying sequential row (left) Givens rotations up to n₂.
"""
function svd_zerodiag_row!(U,B,n₁,n₂)
    e = B.ev[n₁]
    B.dv[n₁] = 0 # set to zero
    B.ev[n₁] = 0

    for i = n₁+1:n₂
        # n₁ [0 ,e ] = G * [e ,0 ]
        #    [ ... ]       [ ... ]
        # i  [dᵢ,eᵢ]       [dᵢ,eᵢ]
        dᵢ = B.dv[i]

        G,r = givens(dᵢ,e,i,n₁)
        A_mul_Bc!(U,G)
        B.dv[i] = r # -G.s*e + G.c*dᵢ

        if i < n₂
            eᵢ = B.ev[i]
            e       = G.s*eᵢ
            B.ev[i] = G.c*eᵢ
        end
    end
end


"""
Sets B[n₂,n₂] to zero, then zeros out column n₂ by applying sequential column (right) Givens rotations up to n₁.
"""
function svd_zerodiag_col!(B,Vt,n₁,n₂)
    e = B.ev[n₂-1]
    B.dv[n₂] = 0 # set to zero
    B.ev[n₂-1] = 0

    for i = n₂-1:-1:n₁
        #   i      n₂     i      n₂
        #  [eᵢ,...,e ] = [eᵢ,...,0 ] * G'
        #  [dᵢ,...,0 ]   [dᵢ,...,e ]
        dᵢ = B.dv[i]

        G,r = givens(dᵢ,e,i,n₂)
        A_mul_B!(G,Vt)

        B.dv[i] = r # G.c*dᵢ + G.s*e

        if n₁ < i
            eᵢ = B.ev[i-1]
            e       = -G.s*eᵢ
            B.ev[i-1] = G.c*eᵢ
        end
    end
end



"""
Applies a Golub-Kahan SVD step.

A Givens rotation is applied to the top 2x2 matrix, and the resulting "bulge" is "chased" down the diagonal to the bottom of the matrix.
"""
function svd_gk!{T<:Real}(B::Bidiagonal{T},U,Vt,n₁,n₂,shift)

    if istriu(B)

        d₁′ = B.dv[n₁]
        e₁′ = B.ev[n₁]
        d₂′ = B.dv[n₁+1]

        G, r = givens(d₁′ - abs2(shift)/d₁′, e₁′, n₁, n₁+1)
        A_mul_B!(G, Vt)

        #  [d₁,e₁] = [d₁′,e₁′] * G'
        #  [b ,d₂]   [0  ,d₂′]


        d₁ =  d₁′*G.c + e₁′*G.s
        e₁ = -d₁′*G.s + e₁′*G.c
        b  =  d₂′*G.s
        d₂ =  d₂′*G.c

        for i = n₁:n₂-2

            #  [. ,e₁′,b′ ] = G * [d₁,e₁,0 ]
            #  [0 ,d₂′,e₂′]       [b ,d₂,e₂]

            e₂ = B.ev[i+1]

            G, r = givens(d₁, b, i, i+1)
            A_mul_Bc!(U, G)

            B.dv[i] =  r # G.c*d₁ + G.s*b

            e₁′ =  G.c*e₁ + G.s*d₂
            d₂′ = -G.s*e₁ + G.c*d₂

            b′  =  G.s*e₂
            e₂′ =  G.c*e₂

            #  [. ,0 ] = [e₁′,b′ ] * G'
            #  [d₁,e₁]   [d₂′,e₂′]
            #  [b ,d₂]   [0  ,d₃′]

            d₃′ = B.dv[i+2]

            G, r = givens(e₁′, b′, i+1, i+2)
            A_mul_B!(G, Vt)

            B.ev[i] = r # e₁′*G.c + b′*G.s

            d₁ =  d₂′*G.c + e₂′*G.s
            e₁ = -d₂′*G.s + e₂′*G.c

            b  = d₃′*G.s
            d₂ = d₃′*G.c
        end

        #  [. ,.] = G * [d₁,e₁]
        #  [0 ,.]       [b ,d₂]

        G, r = givens(d₁,b,n₂-1,n₂)
        A_mul_Bc!(U, G)

        B.dv[n₂-1] =  r # G.c*d₁ + G.s*b

        B.ev[n₂-1] =  G.c*e₁ + G.s*d₂
        B.dv[n₂]   = -G.s*e₁ + G.c*d₂
    else
        throw(ArgumentError("lower bidiagonal version not implemented yet"))
    end

    return B,U,Vt
end


"""
The singular values of the matrix
```
B = [ f g ;
      0 h ]
```
(i.e. the sqrt-eigenvalues of `B'*B`).

This is a direct translation of LAPACK [DLAS2](http://www.netlib.org/lapack/explore-html/d8/dfd/dlas2_8f.html).
"""
function svdvals2x2(f, h, g)
    fa = abs(f)
    ga = abs(g)
    ha = abs(h)

    fhmin = min(fa,ha)
    fhmax = max(fa,ha)

    if fhmin == 0
        ssmin = zero(f)
        if fhmax == 0
            ssmax = zero(f)
        else
            ssmax = max(fhmax,ga)*sqrt(1+(min(fhmax,ga)/max(fhmax,ga))^2)
        end
    else
        if ga < fhmax
            as = 1 + fhmin/fhmax
            at = (fhmax-fhmin)/fhmax
            au = (ga/fhmax)^2
            c = 2/(sqrt(as^2 + au) + sqrt(at^2+au))
            ssmin = fhmin*c
            ssmax = fhmax/c
        else
            au = fhmax / ga
            if au == 0
                ssmin = (fhmin*fhmax)/ga
                ssmax = ga
            else
                as = 1+fhmin/fhmax
                at = (fhmax-fhmin)/fhmax
                c = 1/(sqrt(1 + (as*au)^2) + sqrt(1 + (at*au)^2))
                ssmin = 2((fhmin*c)*au)
                ssmax = ga/(2c)
            end
        end
    end
    ssmin,ssmax
end




end # module
