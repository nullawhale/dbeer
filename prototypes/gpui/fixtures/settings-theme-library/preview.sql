-- Beer inventory
SELECT b.name, round(b.abv, 1) AS strength
FROM public.beers AS b
WHERE b.style = 'IPA' AND b.abv >= 5.5;
