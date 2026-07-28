import { supabase } from "@/lib/supabase";

export default async function Home() {
  const { error } = await supabase.from("teste_conexao").select("*").limit(1);

  return (
    <main className="flex min-h-screen items-center justify-center bg-gray-100">
      <div className="rounded-xl bg-white p-8 shadow-md">
        <h1 className="text-2xl font-bold">AssociedadPlus</h1>

        <p className="mt-4 text-gray-700">
          {error
            ? "O projeto conseguiu acessar o Supabase."
            : "Conexão com o Supabase realizada com sucesso."}
        </p>

        {error && (
          <p className="mt-2 text-sm text-gray-500">
            A tabela de teste ainda não existe, o que é esperado.
          </p>
        )}
      </div>
    </main>
  );
}